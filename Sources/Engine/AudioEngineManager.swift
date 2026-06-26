import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import Observation
import Core

@available(macOS 14.2, *)
private class OutputDeviceEngine {
    let deviceID: AudioDeviceID
    let engine = AVAudioEngine()
    
    var nextBus: AVAudioNodeBus = 0
    var freeBuses: [AVAudioNodeBus] = []
    
    init(deviceID: AudioDeviceID) {
        self.deviceID = deviceID
        setup()
    }
    
    private func setup() {
        // Accessing engine.outputNode lazily instantiates the output node and its
        // AudioUnit, so audioUnit is non-nil and the device property takes effect
        // before we query the format below.
        if deviceID != kAudioObjectUnknown, let outputUnit = engine.outputNode.audioUnit {
            var devID = deviceID
            let status = AudioUnitSetProperty(
                outputUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &devID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr {
                print("OutputDeviceEngine: Failed to set output device \(deviceID) — status \(status)")
            } else {
                print("OutputDeviceEngine: Output device set to \(deviceID)")
            }
        } else if deviceID != kAudioObjectUnknown {
            print("OutputDeviceEngine: outputNode.audioUnit nil — cannot set device \(deviceID), using system default")
        }

        let mixer = engine.mainMixerNode

        do {
            try engine.start()
            print("OutputDeviceEngine: Started engine for device \(deviceID) at \(mixer.outputFormat(forBus: 0).sampleRate)Hz")
        } catch {
            print("OutputDeviceEngine: Failed to start engine for device \(deviceID): \(error)")
        }
    }
    
    func allocateBus() -> AVAudioNodeBus {
        if !freeBuses.isEmpty {
            return freeBuses.removeFirst()
        }
        let bus = nextBus
        nextBus += 1
        return bus
    }
    
    func releaseBus(_ bus: AVAudioNodeBus) {
        freeBuses.append(bus)
    }
}

@available(macOS 14.2, *)
@Observable
@MainActor
public class AudioEngineManager: @unchecked Sendable {
    public static let shared = AudioEngineManager()
    
    public private(set) var isRunning = false
    public private(set) var activeNodes: [String: AppAudioNode] = [:] // Keyed by Bundle ID
    public private(set) var outputDevices: [AudioDevice] = []
    
    public var selectedDeviceID: AudioDeviceID = kAudioObjectUnknown {
        didSet {
            guard selectedDeviceID != oldValue else { return }
            if !_suppressFollowReset {
                followsSystemDefault = false  // user made an explicit choice
                setSystemDefaultOutputDeviceID(selectedDeviceID)
            }
            handleDefaultDeviceChanged(from: oldValue, to: selectedDeviceID)
        }
    }
    
    private struct AppBusRoute: Equatable {
        let deviceID: AudioDeviceID
        let bus: AVAudioNodeBus
    }
    
    private var engines: [AudioDeviceID: OutputDeviceEngine] = [:]
    private var appBusRoutes: [String: AppBusRoute] = [:] // Keyed by Bundle ID
    private var busVolumes: [String: Float] = [:]
    private var isMuted: [String: Bool] = [:]
    private var activePIDs: [String: pid_t] = [:]
    private var followsSystemDefault = true  // false once user explicitly picks a device
    // When true, the selectedDeviceID setter won't reset followsSystemDefault.
    // Used by system-default-changed listener to update selectedDeviceID without
    // marking it as a user-explicit pick.
    private var _suppressFollowReset = false
    
    // Configured output routing: Bundle ID -> AudioDeviceID (kAudioObjectUnknown = Default)
    public private(set) var appOutputDevices: [String: AudioDeviceID] = [:]
    
    // Cached preset settings for bundle IDs that are not currently running
    private var cachedAppSettings: [String: EQPresetData] = [:]
    
    private let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
    private let selectorDefaultOutput = kAudioHardwarePropertyDefaultOutputDevice
    private let selectorDevicesList = kAudioHardwarePropertyDevices
    
    public init() {
        setupEngine()
        setupListeners()
    }
    
    private func setupEngine() {
        let defaultID = getDefaultOutputDeviceID()
        _suppressFollowReset = true
        selectedDeviceID = defaultID
        _suppressFollowReset = false
        followsSystemDefault = true
        refreshDevices()
        if selectedDeviceID != kAudioObjectUnknown {
            _ = getEngine(for: selectedDeviceID)
        }
        isRunning = true
        print("AudioEngineManager: Initialized with multi-engine output support.")
        applyDefaultPreset()
    }
    
    private func getEngine(for deviceID: AudioDeviceID) -> OutputDeviceEngine {
        let actualID = (deviceID == kAudioObjectUnknown) ? selectedDeviceID : deviceID
        if let existing = engines[actualID] {
            return existing
        }
        let newEngine = OutputDeviceEngine(deviceID: actualID)
        engines[actualID] = newEngine
        return newEngine
    }
    
    public func startAppTapping(bundleID: String, pid: pid_t) {
        guard activeNodes[bundleID] == nil else { return }
        activePIDs[bundleID] = pid
        
        // Start tapping in ProcessTapManager
        guard let (ringBuffers, tapFormat) = ProcessTapManager.shared.startTapping(bundleID: bundleID, pid: pid) else {
            print("AudioEngineManager: Failed to start process tap for \(bundleID)")
            return
        }
        
        let targetDeviceID = appOutputDevices[bundleID] ?? kAudioObjectUnknown
        let actualDeviceID = (targetDeviceID == kAudioObjectUnknown) ? selectedDeviceID : targetDeviceID
        let devEngine = getEngine(for: actualDeviceID)
        
        let sampleRate = devEngine.engine.outputNode.outputFormat(forBus: 0).sampleRate
        let resolvedRate = sampleRate > 0 ? sampleRate : 48000.0
        guard let engineFormat = AVAudioFormat(standardFormatWithSampleRate: resolvedRate, channels: 2) else {
            print("AudioEngineManager: Failed to create engine format for \(bundleID)")
            return
        }
        
        guard let appNode = AppAudioNode(ringBuffers: ringBuffers, sourceFormat: tapFormat, engineFormat: engineFormat) else {
            print("AudioEngineManager: Failed to create AppAudioNode for \(bundleID)")
            ProcessTapManager.shared.stopTapping(bundleID: bundleID)
            return
        }
        
        // Dynamic connect
        let bus = devEngine.allocateBus()
        appBusRoutes[bundleID] = AppBusRoute(deviceID: actualDeviceID, bus: bus)
        activeNodes[bundleID] = appNode
        
        devEngine.engine.attach(appNode.sourceNode)
        devEngine.engine.attach(appNode.eqNode)

        devEngine.engine.connect(appNode.sourceNode, to: appNode.eqNode, format: engineFormat)
        devEngine.engine.connect(appNode.eqNode, to: devEngine.engine.mainMixerNode, fromBus: 0, toBus: bus, format: engineFormat)
        
        // Ensure engine is running and active
        try? devEngine.engine.start()

        // Check if we have cached preset settings for this app
        if let cached = cachedAppSettings[bundleID] {
            appNode.eqController.applyPresetData(cached)
            busVolumes[bundleID] = cached.volume
        }

        // Apply volume directly to the app node
        let vol = busVolumes[bundleID] ?? 1.0
        let muted = isMuted[bundleID] ?? false
        appNode.volume = muted ? 0.0 : vol
        
        print("AudioEngineManager: Attached and connected \(bundleID) on engine device \(actualDeviceID) bus \(bus)")
    }
    
    public func stopAppTapping(bundleID: String) {
        activePIDs.removeValue(forKey: bundleID)
        guard let appNode = activeNodes.removeValue(forKey: bundleID) else { return }
        guard let route = appBusRoutes.removeValue(forKey: bundleID) else { return }
        
        if let devEngine = engines[route.deviceID] {
            devEngine.engine.disconnectNodeInput(devEngine.engine.mainMixerNode, bus: route.bus)
            devEngine.engine.disconnectNodeInput(appNode.eqNode, bus: 0)

            devEngine.engine.detach(appNode.eqNode)
            devEngine.engine.detach(appNode.sourceNode)

            devEngine.releaseBus(route.bus)
        }

        ProcessTapManager.shared.stopTapping(bundleID: bundleID)
        print("AudioEngineManager: Detached and stopped tapping \(bundleID) from engine device \(route.deviceID)")
    }
    
    // Per-app output routing setter
    public func setAppOutputDevice(bundleID: String, deviceID: AudioDeviceID) {
        let oldDeviceID = appOutputDevices[bundleID] ?? kAudioObjectUnknown
        appOutputDevices[bundleID] = deviceID
        
        guard oldDeviceID != deviceID else { return }
        print("AudioEngineManager: Routing \(bundleID) from device \(oldDeviceID) → \(deviceID)")
        
        if activePIDs[bundleID] != nil {
            routeActiveNode(bundleID: bundleID, fromDevice: oldDeviceID, toDevice: deviceID)
        }
    }
    
    public func getAppOutputDevice(bundleID: String) -> AudioDeviceID {
        return appOutputDevices[bundleID] ?? kAudioObjectUnknown
    }
    
    private func handleDefaultDeviceChanged(from oldDeviceID: AudioDeviceID, to newDeviceID: AudioDeviceID) {
        guard oldDeviceID != newDeviceID else { return }
        print("AudioEngineManager: Default device changed from \(oldDeviceID) to \(newDeviceID). Migrating default-routed apps...")
        
        // Find all active apps that are routed to kAudioObjectUnknown (Default Output)
        for (bundleID, targetDevice) in appOutputDevices {
            if targetDevice == kAudioObjectUnknown {
                migrateActiveNode(bundleID: bundleID, fromDevice: oldDeviceID, toDevice: newDeviceID)
            }
        }
        // Also check any active nodes that are not explicitly in appOutputDevices
        for bundleID in activeNodes.keys {
            if appOutputDevices[bundleID] == nil {
                migrateActiveNode(bundleID: bundleID, fromDevice: oldDeviceID, toDevice: newDeviceID)
            }
        }
    }
    
    private func migrateActiveNode(bundleID: String, fromDevice: AudioDeviceID, toDevice: AudioDeviceID) {
        guard activeNodes[bundleID] != nil else { return }
        guard let oldRoute = appBusRoutes[bundleID], oldRoute.deviceID == fromDevice else { return }

        print("AudioEngineManager: Migrating active node \(bundleID) from default device \(fromDevice) to \(toDevice)")
        routeActiveNode(bundleID: bundleID, fromDevice: fromDevice, toDevice: toDevice)
    }
    
    private func routeActiveNode(bundleID: String, fromDevice: AudioDeviceID, toDevice: AudioDeviceID) {
        guard let appNode = activeNodes.removeValue(forKey: bundleID) else { return }
        guard let oldRoute = appBusRoutes.removeValue(forKey: bundleID) else { return }
        
        // 1. Detach from old engine
        let actualOldDeviceID = (fromDevice == kAudioObjectUnknown) ? selectedDeviceID : fromDevice
        if let oldEngine = engines[actualOldDeviceID] {
            oldEngine.engine.disconnectNodeInput(oldEngine.engine.mainMixerNode, bus: oldRoute.bus)
            oldEngine.engine.disconnectNodeInput(appNode.eqNode, bus: 0)

            oldEngine.engine.detach(appNode.eqNode)
            oldEngine.engine.detach(appNode.sourceNode)

            oldEngine.releaseBus(oldRoute.bus)
        }
        
        // 2. Attach to new engine
        let actualNewDeviceID = (toDevice == kAudioObjectUnknown) ? selectedDeviceID : toDevice
        let devEngine = getEngine(for: actualNewDeviceID)
        
        let sampleRate = devEngine.engine.outputNode.outputFormat(forBus: 0).sampleRate
        let resolvedRate = sampleRate > 0 ? sampleRate : 48000.0
        
        guard let ringBuffers = ProcessTapManager.shared.getRingBuffers(bundleID: bundleID),
              let tapFormat = ProcessTapManager.shared.getActiveTapFormat(bundleID: bundleID) else {
            print("AudioEngineManager: Failed to get active tap info for routing \(bundleID)")
            return
        }
        
        guard let engineFormat = AVAudioFormat(standardFormatWithSampleRate: resolvedRate, channels: 2) else {
            print("AudioEngineManager: Failed to create engine format for routing \(bundleID)")
            return
        }
        
        guard let newAppNode = AppAudioNode(ringBuffers: ringBuffers, sourceFormat: tapFormat, engineFormat: engineFormat) else {
            print("AudioEngineManager: Failed to create AppAudioNode for routing \(bundleID)")
            return
        }
        
        let bus = devEngine.allocateBus()
        appBusRoutes[bundleID] = AppBusRoute(deviceID: actualNewDeviceID, bus: bus)
        activeNodes[bundleID] = newAppNode
        
        devEngine.engine.attach(newAppNode.sourceNode)
        devEngine.engine.attach(newAppNode.eqNode)

        devEngine.engine.connect(newAppNode.sourceNode, to: newAppNode.eqNode, format: engineFormat)
        devEngine.engine.connect(newAppNode.eqNode, to: devEngine.engine.mainMixerNode, fromBus: 0, toBus: bus, format: engineFormat)
        
        try? devEngine.engine.start()
        
        // Restore volume and EQ settings
        let oldVol = busVolumes[bundleID] ?? 1.0
        let oldPreset = appNode.eqController.getPresetData(volume: oldVol)
        newAppNode.eqController.applyPresetData(oldPreset)
        
        let muted = isMuted[bundleID] ?? false
        newAppNode.volume = muted ? 0.0 : oldVol
        
        print("AudioEngineManager: Successfully routed \(bundleID) to device \(actualNewDeviceID) bus \(bus)")
    }
    
    // VU Meter Level Pull (Placeholder)
    public func getRMS(for bundleID: String) -> Float {
        return 0.0
    }
    
    // Volume Control
    public func setVolume(bundleID: String, volume: Float) {
        busVolumes[bundleID] = volume
        if let appNode = activeNodes[bundleID] {
            let muted = isMuted[bundleID] ?? false
            appNode.volume = muted ? 0.0 : volume
        }
    }
    
    public func getVolume(bundleID: String) -> Float {
        return busVolumes[bundleID] ?? 1.0
    }
    
    // Mute Control
    public func setMute(bundleID: String, muted: Bool) {
        isMuted[bundleID] = muted
        if let appNode = activeNodes[bundleID] {
            let vol = getVolume(bundleID: bundleID)
            appNode.volume = muted ? 0.0 : vol
        }
    }
    
    public func getMute(bundleID: String) -> Bool {
        return isMuted[bundleID] ?? false
    }
    
    // Presets
    public func saveCurrentStateAsPreset(name: String) {
        var appSettings: [String: EQPresetData] = [:]
        
        for (bundleID, appNode) in activeNodes {
            let volume = getVolume(bundleID: bundleID)
            let data = appNode.eqController.getPresetData(volume: volume)
            appSettings[bundleID] = data
        }
        
        for (bundleID, cached) in cachedAppSettings {
            if appSettings[bundleID] == nil {
                appSettings[bundleID] = cached
            }
        }
        
        PresetStore.shared.savePreset(name: name, appSettings: appSettings)
    }
    
    public func loadPreset(name: String) {
        guard let preset = PresetStore.shared.presets.first(where: { $0.name == name }) else { return }
        
        for (bundleID, appPresetData) in preset.appSettings {
            cachedAppSettings[bundleID] = appPresetData
            
            if let appNode = activeNodes[bundleID] {
                appNode.eqController.applyPresetData(appPresetData)
                setVolume(bundleID: bundleID, volume: appPresetData.volume)
            }
        }
    }
    
    private func applyDefaultPreset() {
        if let def = PresetStore.shared.defaultPreset {
            loadPreset(name: def.name)
        }
    }
    
    private func setNodeVolume(_ node: AVAudioNode, _ volume: Float) {
        if let mixing = node as? AVAudioMixing {
            mixing.volume = volume
        }
    }
    
    // Device Management
    public func refreshDevices() {
        var address = AudioObjectPropertyAddress(
            mSelector: selectorDevicesList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(systemObjectID, &address, 0, nil, &size)
        guard status == noErr else { return }
        
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(systemObjectID, &address, 0, nil, &size, &deviceIDs)
        guard status == noErr else { return }
        
        var newDevices: [AudioDevice] = []
        for devID in deviceIDs {
            var streamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            status = AudioObjectGetPropertyDataSize(devID, &streamAddress, 0, nil, &streamSize)
            guard status == noErr && streamSize > 0 else { continue }
            
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameCF: Unmanaged<CFString>? = nil
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            status = AudioObjectGetPropertyData(devID, &nameAddress, 0, nil, &nameSize, &nameCF)
            
            let name: String
            if status == noErr, let cf = nameCF {
                name = cf.takeRetainedValue() as String
            } else {
                name = "Unknown Output Device"
            }
            
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidCF: Unmanaged<CFString>? = nil
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            status = AudioObjectGetPropertyData(devID, &uidAddress, 0, nil, &uidSize, &uidCF)
            
            let uid: String
            if status == noErr, let cf = uidCF {
                uid = cf.takeRetainedValue() as String
            } else {
                uid = UUID().uuidString
            }
            
            newDevices.append(AudioDevice(deviceID: devID, name: name, uid: uid))
        }
        
        self.outputDevices = newDevices
        if self.selectedDeviceID == kAudioObjectUnknown {
            self.selectedDeviceID = self.getDefaultOutputDeviceID()
        }
    }
    
    private func getDefaultOutputDeviceID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: selectorDefaultOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(systemObjectID, &address, 0, nil, &size, &deviceID)
        return status == noErr ? deviceID : kAudioObjectUnknown
    }
    
    private func setSystemDefaultOutputDeviceID(_ deviceID: AudioDeviceID) {
        guard deviceID != kAudioObjectUnknown else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: selectorDefaultOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var tempID = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectSetPropertyData(systemObjectID, &address, 0, nil, size, &tempID)
        if status != noErr {
            print("AudioEngineManager: Failed to set system default output device to \(deviceID), error \(status)")
        } else {
            print("AudioEngineManager: Successfully set system default output device to \(deviceID)")
        }
    }
    
    // Listeners
    private func setupListeners() {
        let clientData = Unmanaged.passUnretained(self).toOpaque()

        // Device list changed: refresh picker items only — never change selectedDeviceID here.
        // Private aggregate devices created per-tap also trigger this; ignore them.
        var listAddress = AudioObjectPropertyAddress(
            mSelector: selectorDevicesList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let deviceListProc: AudioObjectPropertyListenerProc = { _, _, _, inClientData in
            guard let data = inClientData else { return noErr }
            let mgr = Unmanaged<AudioEngineManager>.fromOpaque(data).takeUnretainedValue()
            Task { @MainActor in
                let prevID = mgr.selectedDeviceID
                mgr.refreshDevices()
                // If current device was removed (unplugged), fall back to system default.
                if !mgr.outputDevices.contains(where: { $0.deviceID == prevID }) {
                    let fallback = mgr.getDefaultOutputDeviceID()
                    if fallback != prevID {
                        mgr._suppressFollowReset = true
                        mgr.selectedDeviceID = fallback
                        mgr._suppressFollowReset = false
                        mgr.followsSystemDefault = true
                    }
                }
            }
            return noErr
        }
        AudioObjectAddPropertyListener(systemObjectID, &listAddress, deviceListProc, clientData)

        // System default output changed: follow only if user hasn't made a manual pick.
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: selectorDefaultOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let defaultOutputProc: AudioObjectPropertyListenerProc = { _, _, _, inClientData in
            guard let data = inClientData else { return noErr }
            let mgr = Unmanaged<AudioEngineManager>.fromOpaque(data).takeUnretainedValue()
            Task { @MainActor in
                guard mgr.followsSystemDefault else {
                    print("AudioEngineManager: System default changed but user has explicit pick — ignoring")
                    return
                }
                let sysDefault = mgr.getDefaultOutputDeviceID()
                if mgr.selectedDeviceID != sysDefault {
                    print("AudioEngineManager: Following system default device change → \(sysDefault)")
                    mgr._suppressFollowReset = true
                    mgr.selectedDeviceID = sysDefault
                    mgr._suppressFollowReset = false
                    mgr.followsSystemDefault = true
                }
            }
            return noErr
        }
        AudioObjectAddPropertyListener(systemObjectID, &defaultAddress, defaultOutputProc, clientData)
    }
}
