import Foundation
import AppKit
import CoreAudio
import Observation

private let processListChangedProc: AudioObjectPropertyListenerProc = { inObjectID, inNumberAddresses, inAddresses, inClientData in
    guard let clientData = inClientData else { return noErr }
    let enumerator = Unmanaged<AudioProcessEnumerator>.fromOpaque(clientData).takeUnretainedValue()
    Task { @MainActor [weak enumerator] in
        enumerator?.refresh()
    }
    return noErr
}

@Observable
@MainActor
public class AudioProcessEnumerator: @unchecked Sendable {
    public var processes: [AudioProcess] = []
    
    @ObservationIgnored nonisolated(unsafe) private var isListening = false
    @ObservationIgnored nonisolated(unsafe) private var listenerPointer: UnsafeMutableRawPointer? = nil
    
    private let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
    
    // Explicit selector constants using 4-character codes if not resolved by compiler
    private let selectorProcessObjectList: AudioObjectPropertySelector = 0x70727323 // 'prs#'
    private let selectorProcessPID: AudioObjectPropertySelector = 0x70706964        // 'ppid'
    private let selectorProcessBundleID: AudioObjectPropertySelector = 0x70626964   // 'pbid'
    private let selectorProcessIsRunningOutput: AudioObjectPropertySelector = 0x7069726f // 'piro'
    
    public init() {
        refresh()
        setupNotifications()
        setupCoreAudioListener()
    }
    
    deinit {
        // Core Audio listener removal must be done carefully.
        // We capture parameters needed to clean it up since deinit runs on the deallocating thread.
        let wasListening = isListening
        let pointer = listenerPointer
        let systemId = systemObjectID
        let selector = selectorProcessObjectList
        
        if wasListening, let ptr = pointer {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListener(systemId, &address, processListChangedProc, ptr)
        }
    }
    
    public func refresh() {
        var address = AudioObjectPropertyAddress(
            mSelector: selectorProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(systemObjectID, &address, 0, nil, &size)
        guard status == noErr else {
            print("AudioProcessEnumerator: Failed to get process list size: \(status)")
            return
        }
        
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var processIDs = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(systemObjectID, &address, 0, nil, &size, &processIDs)
        guard status == noErr else {
            print("AudioProcessEnumerator: Failed to get process list: \(status)")
            return
        }
        
        let currentBundleID = Bundle.main.bundleIdentifier
        var coreAudioProcesses: [String: AudioProcess] = [:]
 
        for processID in processIDs {
            // Get PID
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: selectorProcessPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            status = AudioObjectGetPropertyData(processID, &pidAddress, 0, nil, &pidSize, &pid)
            guard status == noErr else { continue }
            
            // Get Bundle ID
            var bundleAddress = AudioObjectPropertyAddress(
                mSelector: selectorProcessBundleID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var bundleIDCF: Unmanaged<CFString>? = nil
            var bundleIDSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            status = AudioObjectGetPropertyData(processID, &bundleAddress, 0, nil, &bundleIDSize, &bundleIDCF)
            
            let bundleID: String
            if status == noErr, let cf = bundleIDCF {
                bundleID = AudioProcess.normalizeBundleID(cf.takeRetainedValue() as String)
            } else {
                bundleID = ""
            }
            
            // Skip helper agents or this application itself
            if bundleID == currentBundleID || bundleID == "com.apple.audio.AudioComponentRegistrar" {
                continue
            }
            
            // Check if process is running output
            var outputAddress = AudioObjectPropertyAddress(
                mSelector: selectorProcessIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var isRunningOutputVal: UInt32 = 0
            var outputSize = UInt32(MemoryLayout<UInt32>.size)
            status = AudioObjectGetPropertyData(processID, &outputAddress, 0, nil, &outputSize, &isRunningOutputVal)
            let isRunningOutput = (status == noErr && isRunningOutputVal != 0)
            
            // Get application name and icon.
            var name = ""
            var icon: NSImage? = nil
            var isRegularApp = false
 
            if let runningApp = NSRunningApplication(processIdentifier: pid),
               runningApp.activationPolicy == .regular {
                name = runningApp.localizedName ?? ""
                icon = runningApp.icon
                isRegularApp = true
            } else if let owner = resolveOwningApp(pid: pid, bundleID: bundleID) {
                name = owner.name
                icon = owner.icon
                isRegularApp = true
            }
 
            if name.isEmpty {
                // Fallback to bundle ID or process name
                if !bundleID.isEmpty {
                    name = bundleID.components(separatedBy: ".").last ?? bundleID
                } else {
                    name = "Process \(pid)"
                }
            }
 
            let process = AudioProcess(
                audioObjectID: processID,
                pid: pid,
                bundleID: bundleID,
                name: name,
                icon: icon,
                isRunningOutput: isRunningOutput,
                isRegularApp: isRegularApp
            )
            
            let key = bundleID.isEmpty ? name : bundleID
            if let existing = coreAudioProcesses[key] {
                let mergedIsRunningOutput = existing.isRunningOutput || isRunningOutput
                let mergedIsRegularApp = existing.isRegularApp || isRegularApp
                let mergedIcon = existing.icon ?? icon
                
                let mergedAudioObjectID: AudioObjectID
                let mergedPid: pid_t
                if existing.audioObjectID != 0 {
                    mergedAudioObjectID = existing.audioObjectID
                    mergedPid = existing.pid
                } else {
                    mergedAudioObjectID = processID
                    mergedPid = pid
                }
                
                let mergedName = existing.name.isEmpty ? name : existing.name
                
                coreAudioProcesses[key] = AudioProcess(
                    audioObjectID: mergedAudioObjectID,
                    pid: mergedPid,
                    bundleID: existing.bundleID.isEmpty ? bundleID : existing.bundleID,
                    name: mergedName,
                    icon: mergedIcon,
                    isRunningOutput: mergedIsRunningOutput,
                    isRegularApp: mergedIsRegularApp
                )
            } else {
                coreAudioProcesses[key] = process
            }
        }
 
        // Merge with all running applications via NSWorkspace
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular else { continue }
            guard let bundleID = app.bundleIdentifier else { continue }
            if bundleID == currentBundleID || bundleID == "com.apple.audio.AudioComponentRegistrar" {
                continue
            }
            
            let key = AudioProcess.normalizeBundleID(bundleID)
            if let existing = coreAudioProcesses[key] {
                var updated = existing
                updated.isRegularApp = true
                if updated.icon == nil {
                    updated = AudioProcess(
                        audioObjectID: existing.audioObjectID,
                        pid: existing.pid,
                        bundleID: existing.bundleID,
                        name: existing.name,
                        icon: app.icon,
                        isRunningOutput: existing.isRunningOutput,
                        isRegularApp: true
                    )
                }
                coreAudioProcesses[key] = updated
            } else {
                let process = AudioProcess(
                    audioObjectID: 0,
                    pid: app.processIdentifier,
                    bundleID: bundleID,
                    name: app.localizedName ?? bundleID,
                    icon: app.icon,
                    isRunningOutput: false,
                    isRegularApp: true
                )
                coreAudioProcesses[key] = process
            }
        }
 
        self.processes = Array(coreAudioProcesses.values)
    }
    
    // Walk up the parent-PID chain (max 5 hops) to find the first ancestor that is a
    // regular foreground app, so helper/renderer processes inherit their app's name + icon.
    // Falls back to bundle ID prefix matching for sandboxed browsers (Chrome, Edge) whose
    // helper processes block sysctl KERN_PROC_PID, cutting the PID chain walk short.
    private func resolveOwningApp(pid: pid_t, bundleID: String = "") -> (name: String, icon: NSImage?)? {
        var current = pid
        var depth = 0
        while depth < 5 {
            if let app = NSRunningApplication(processIdentifier: current),
               app.activationPolicy == .regular {
                return (app.localizedName ?? "", app.icon)
            }
            guard let parent = parentPID(of: current), parent > 1, parent != current else { break }
            current = parent
            depth += 1
        }
 
        // Chrome helpers have bundle IDs like "com.google.Chrome.helper.renderer".
        // Strip trailing components one by one until we match a running .regular app.
        if !bundleID.isEmpty {
            let parts = bundleID.components(separatedBy: ".")
            for length in stride(from: parts.count - 1, through: 2, by: -1) {
                let prefix = parts.prefix(length).joined(separator: ".")
                if let app = NSRunningApplication.runningApplications(withBundleIdentifier: prefix)
                    .first(where: { $0.activationPolicy == .regular }) {
                    return (app.localizedName ?? "", app.icon)
                }
            }
        }
 
        return nil
    }
 
    // Parent PID via sysctl(KERN_PROC_PID).
    private func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
 
    private func setupNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.refresh()
            }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.refresh()
            }
        }
    }
    
    private func setupCoreAudioListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: selectorProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let clientData = Unmanaged.passUnretained(self).toOpaque()
        let status = AudioObjectAddPropertyListener(systemObjectID, &address, processListChangedProc, clientData)
        if status == noErr {
            isListening = true
            listenerPointer = clientData
        } else {
            print("AudioProcessEnumerator: Failed to add property listener: \(status)")
        }
    }
}
