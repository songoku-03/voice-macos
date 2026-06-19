import Foundation
import AppKit
import CoreAudio
import Observation

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
            let listenerProc: AudioObjectPropertyListenerProc = { _, _, _, _ in noErr }
            AudioObjectRemovePropertyListener(systemId, &address, listenerProc, ptr)
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
        
        var newProcesses: [AudioProcess] = []
        let currentBundleID = Bundle.main.bundleIdentifier
        
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
                bundleID = cf.takeRetainedValue() as String
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
            // Browsers (Chrome, CocCoc, Edge) and Electron apps (Discord) play audio
            // through child "Helper (Renderer)" processes that have no NSRunningApplication
            // of their own. Walk up the parent-PID chain to find the real owning app so the
            // row shows e.g. "Google Chrome" + icon instead of a bare "helper".
            var name = ""
            var icon: NSImage? = nil

            if let runningApp = NSRunningApplication(processIdentifier: pid),
               runningApp.activationPolicy == .regular {
                name = runningApp.localizedName ?? ""
                icon = runningApp.icon
            } else if let owner = resolveOwningApp(pid: pid) {
                name = owner.name
                icon = owner.icon
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
                isRunningOutput: isRunningOutput
            )
            newProcesses.append(process)
        }
        
        self.processes = newProcesses
    }
    
    // Walk up the parent-PID chain (max 5 hops) to find the first ancestor that is a
    // regular foreground app, so helper/renderer processes inherit their app's name + icon.
    private func resolveOwningApp(pid: pid_t) -> (name: String, icon: NSImage?)? {
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
        let listenerProc: AudioObjectPropertyListenerProc = { inObjectID, inNumberAddresses, inAddresses, inClientData in
            guard let clientData = inClientData else { return noErr }
            let enumerator = Unmanaged<AudioProcessEnumerator>.fromOpaque(clientData).takeUnretainedValue()
            Task { @MainActor in
                enumerator.refresh()
            }
            return noErr
        }
        
        let status = AudioObjectAddPropertyListener(systemObjectID, &address, listenerProc, clientData)
        if status == noErr {
            isListening = true
            listenerPointer = clientData
        } else {
            print("AudioProcessEnumerator: Failed to add property listener: \(status)")
        }
    }
}
