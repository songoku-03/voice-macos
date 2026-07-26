import Foundation
import AppKit
import AVFoundation
import CoreAudio
import AudioToolbox
import Observation
import Core
import Darwin

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
private let deviceListProc: AudioObjectPropertyListenerProc = { _, _, _, inClientData in
    guard let data = inClientData else { return noErr }
    let mgr = Unmanaged<AudioEngineManager>.fromOpaque(data).takeUnretainedValue()
    Task { @MainActor in
        mgr.handleDeviceListChanged()
    }
    return noErr
}

@available(macOS 14.2, *)
private let defaultOutputProc: AudioObjectPropertyListenerProc = { _, _, _, inClientData in
    guard let data = inClientData else { return noErr }
    let mgr = Unmanaged<AudioEngineManager>.fromOpaque(data).takeUnretainedValue()
    Task { @MainActor in
        mgr.handleDefaultOutputChanged()
    }
    return noErr
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
            saveStateToUserDefaults()
            handleDefaultDeviceChanged(from: oldValue, to: selectedDeviceID)
        }
    }
    
    private struct AppBusRoute: Equatable {
        let deviceID: AudioDeviceID
        let bus: AVAudioNodeBus
    }
    
    @ObservationIgnored nonisolated(unsafe) private var engines: [AudioDeviceID: OutputDeviceEngine] = [:]
    @ObservationIgnored nonisolated(unsafe) private var livenessTimer: Timer?
    private var appBusRoutes: [String: AppBusRoute] = [:] // Keyed by Bundle ID
    private var busVolumes: [String: Float] = [:]
    private var isMuted: [String: Bool] = [:]
    private var activePIDs: [String: pid_t] = [:]
    private var desiredTappedBundleIDs: Set<String> = []
    var followsSystemDefault: Bool {
        get {
            UserDefaults.standard.object(forKey: "followsSystemDefault") as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "followsSystemDefault")
        }
    }
    // When true, the selectedDeviceID setter won't reset followsSystemDefault.
    // Used by system-default-changed listener to update selectedDeviceID without
    // marking it as a user-explicit pick.
    private var _suppressFollowReset = false
    private var _suppressSaveState = false
    private var deviceIDsChangingConfig = Set<AudioDeviceID>()
    
    // Configured output routing: Bundle ID -> AudioDeviceID (kAudioObjectUnknown = Default)
    public private(set) var appOutputDevices: [String: AudioDeviceID] = [:]
    
    // Live per-app EQ settings (curve + bypass), keyed by bundle ID. Snapshotted
    // from the node before every detach and persisted to app-settings.json so
    // state survives re-taps and app restarts.
    private var cachedAppSettings: [String: EQPresetData] = [:]

    // Observable EQ bypass flags the UI binds to (mirrors isMuted). Every write
    // path keeps this in sync with cachedAppSettings[bundleID].bypass.
    public private(set) var eqBypass: [String: Bool] = [:]

    @ObservationIgnored private let appSettingsRepository: AppSettingsRepository
    // Chains fire-and-forget settings saves so they land on disk in call order.
    @ObservationIgnored private var pendingSettingsSave: Task<Void, Never>?
    
    #if DEBUG
    public var tapProvider: ((String, pid_t) -> ([RingBuffer], AudioStreamBasicDescription)?)? = nil
    #endif
    
    private let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
    private let selectorDefaultOutput = kAudioHardwarePropertyDefaultOutputDevice
    private let selectorDevicesList = kAudioHardwarePropertyDevices
    
    public init(fileStore: FileStoring = DefaultFileStore(), appSettingsFileURL: URL = AppSettingsRepository.defaultFileURL()) {
        self.appSettingsRepository = AppSettingsRepository(fileStore: fileStore, fileURL: appSettingsFileURL)
        // Synchronous load so cached EQ state exists before setupEngine resumes taps.
        let persisted = AppSettingsRepository.loadSynchronously(fileStore: fileStore, fileURL: appSettingsFileURL)
        self.cachedAppSettings = persisted
        self.eqBypass = persisted.mapValues { $0.bypass }
        setupEngine()
        setupListeners()
    }
    
    deinit {
        let clientData = Unmanaged.passUnretained(self).toOpaque()
        
        var listAddress = AudioObjectPropertyAddress(
            mSelector: selectorDevicesList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListener(systemObjectID, &listAddress, deviceListProc, clientData)
        
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: selectorDefaultOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListener(systemObjectID, &defaultAddress, defaultOutputProc, clientData)
        
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        
        livenessTimer?.invalidate()
        livenessTimer = nil
        
        for devEngine in engines.values {
            devEngine.engine.stop()
        }
        engines.removeAll()
    }
    
    private func saveStateToUserDefaults() {
        guard !_suppressSaveState else { return }
        if let device = outputDevices.first(where: { $0.deviceID == selectedDeviceID }) {
            UserDefaults.standard.set(device.uid, forKey: "selectedDeviceUID")
        } else if selectedDeviceID == kAudioObjectUnknown {
            UserDefaults.standard.removeObject(forKey: "selectedDeviceUID")
        }
    }
    
    private func setupEngine() {
        _suppressSaveState = true
        defer {
            _suppressSaveState = false
        }
        
        refreshDevices()
        
        let savedFollows = UserDefaults.standard.object(forKey: "followsSystemDefault") as? Bool ?? true
        let savedUID = UserDefaults.standard.string(forKey: "selectedDeviceUID")
        
        let sysDefaultID = getDefaultOutputDeviceID()
        
        var targetID = sysDefaultID
        var resolvedFollows = savedFollows
        
        if !savedFollows, let uid = savedUID {
            if let device = outputDevices.first(where: { $0.uid == uid }) {
                targetID = device.deviceID
            } else {
                targetID = sysDefaultID
            }
        } else {
            resolvedFollows = true
        }
        
        _suppressFollowReset = true
        selectedDeviceID = targetID
        _suppressFollowReset = false
        followsSystemDefault = resolvedFollows
        
        if selectedDeviceID != kAudioObjectUnknown {
            _ = getEngine(for: selectedDeviceID)
        }
        isRunning = true
        print("AudioEngineManager: Initialized with multi-engine output support. followsSystemDefault=\(followsSystemDefault), selectedDeviceID=\(selectedDeviceID)")
        applyDefaultPreset()
        
        // Load desiredTappedBundleIDs and auto-resume tapping for running matches
        let savedIDs = UserDefaults.standard.stringArray(forKey: "desiredTappedBundleIDs") ?? []
        self.desiredTappedBundleIDs = Set(savedIDs)
        for app in NSWorkspace.shared.runningApplications {
            if let bundleID = app.bundleIdentifier, self.desiredTappedBundleIDs.contains(bundleID) {
                let pid = app.processIdentifier
                self.startAppTapping(bundleID: bundleID, pid: pid)
            }
        }
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
        desiredTappedBundleIDs.insert(bundleID)
        UserDefaults.standard.set(Array(desiredTappedBundleIDs), forKey: "desiredTappedBundleIDs")
        activePIDs[bundleID] = pid
        print("AudioEngineManager: startAppTapping for \(bundleID) with PID \(pid)")
        
        // Start tapping in ProcessTapManager
        let tapResult: ([RingBuffer], AudioStreamBasicDescription)?
        #if DEBUG
        if let provider = tapProvider {
            tapResult = provider(bundleID, pid)
        } else {
            tapResult = ProcessTapManager.shared.startTapping(bundleID: bundleID, pid: pid)
        }
        #else
        tapResult = ProcessTapManager.shared.startTapping(bundleID: bundleID, pid: pid)
        #endif

        guard let (ringBuffers, tapFormat) = tapResult else {
            print("AudioEngineManager: Failed to start process tap for \(bundleID)")
            activePIDs.removeValue(forKey: bundleID)
            return
        }
        
        let targetDeviceID = appOutputDevices[bundleID] ?? kAudioObjectUnknown
        let actualDeviceID = (targetDeviceID == kAudioObjectUnknown) ? selectedDeviceID : targetDeviceID
        let devEngine = getEngine(for: actualDeviceID)
        
        let sampleRate = devEngine.engine.outputNode.outputFormat(forBus: 0).sampleRate
        let resolvedRate = sampleRate > 0 ? sampleRate : 48000.0
        guard let engineFormat = AVAudioFormat(standardFormatWithSampleRate: resolvedRate, channels: 2) else {
            print("AudioEngineManager: Failed to create engine format for \(bundleID)")
            ProcessTapManager.shared.stopTapping(bundleID: bundleID)
            activePIDs.removeValue(forKey: bundleID)
            return
        }
        
        guard let appNode = AppAudioNode(ringBuffers: ringBuffers, sourceFormat: tapFormat, engineFormat: engineFormat) else {
            print("AudioEngineManager: Failed to create AppAudioNode for \(bundleID)")
            ProcessTapManager.shared.stopTapping(bundleID: bundleID)
            activePIDs.removeValue(forKey: bundleID)
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

        // Bypass may have been toggled while the app wasn't tapped; the dict wins.
        if let bypassed = eqBypass[bundleID] {
            appNode.eqController.setBypass(bypassed)
        } else {
            eqBypass[bundleID] = appNode.eqController.avAudioUnit.bypass
        }

        // Apply volume directly to the app node
        let vol = busVolumes[bundleID] ?? 1.0
        let muted = isMuted[bundleID] ?? false
        appNode.volume = muted ? 0.0 : vol
        
        print("AudioEngineManager: Attached and connected \(bundleID) on engine device \(actualDeviceID) bus \(bus)")
        
        // Wire up ducking if currently breaking (6.3)
        BreakTimerManager.shared.duckNewNode(bundleID: bundleID, manager: self)
    }
    
    public func userStopAppTapping(bundleID: String) {
        desiredTappedBundleIDs.remove(bundleID)
        UserDefaults.standard.set(Array(desiredTappedBundleIDs), forKey: "desiredTappedBundleIDs")
        stopAppTapping(bundleID: bundleID)
    }
    
    public func stopAppTapping(bundleID: String) {
        activePIDs.removeValue(forKey: bundleID)
        guard let appNode = activeNodes.removeValue(forKey: bundleID) else { return }
        guard let route = appBusRoutes.removeValue(forKey: bundleID) else { return }

        // Snapshot EQ state (curve + bypass) before the node is detached so a
        // re-tap — or the next launch — restores it (mirrors volume/mute).
        snapshotEQSettings(bundleID: bundleID, from: appNode)

        // Safety: Immediately set volume to 0.0 before disconnecting/detaching
        appNode.volume = 0.0
        
        if let devEngine = engines[route.deviceID] {
            devEngine.engine.disconnectNodeInput(devEngine.engine.mainMixerNode, bus: route.bus)
            devEngine.engine.disconnectNodeInput(appNode.eqNode, bus: 0)

            devEngine.engine.detach(appNode.eqNode)
            devEngine.engine.detach(appNode.sourceNode)

            devEngine.releaseBus(route.bus)
        }

        ProcessTapManager.shared.stopTapping(bundleID: bundleID)
        print("AudioEngineManager: Detached and stopped tapping \(bundleID) from engine device \(route.deviceID)")
        cleanupIdleEngines()
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
        cleanupIdleEngines()
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
        let actualOldDeviceID = oldRoute.deviceID
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
            ProcessTapManager.shared.stopTapping(bundleID: bundleID)
            activePIDs.removeValue(forKey: bundleID)
            cleanupIdleEngines()
            return
        }
        
        guard let engineFormat = AVAudioFormat(standardFormatWithSampleRate: resolvedRate, channels: 2) else {
            print("AudioEngineManager: Failed to create engine format for routing \(bundleID)")
            ProcessTapManager.shared.stopTapping(bundleID: bundleID)
            activePIDs.removeValue(forKey: bundleID)
            cleanupIdleEngines()
            return
        }
        
        guard let newAppNode = AppAudioNode(ringBuffers: ringBuffers, sourceFormat: tapFormat, engineFormat: engineFormat) else {
            print("AudioEngineManager: Failed to create AppAudioNode for routing \(bundleID)")
            ProcessTapManager.shared.stopTapping(bundleID: bundleID)
            activePIDs.removeValue(forKey: bundleID)
            cleanupIdleEngines()
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
        cachedAppSettings[bundleID] = oldPreset
        eqBypass[bundleID] = oldPreset.bypass
        persistAppSettings()
        
        let muted = isMuted[bundleID] ?? false
        newAppNode.volume = muted ? 0.0 : oldVol
        
        print("AudioEngineManager: Successfully routed \(bundleID) to device \(actualNewDeviceID) bus \(bus)")
        cleanupIdleEngines()
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
            if BreakTimerManager.shared.phase == .breaking {
                appNode.volume = muted ? 0.0 : volume * 0.1
                BreakTimerManager.shared.updatePreBreakVolume(bundleID: bundleID, volume: volume)
            } else {
                appNode.volume = muted ? 0.0 : volume
            }
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
            if BreakTimerManager.shared.phase == .breaking {
                appNode.volume = muted ? 0.0 : vol * 0.1
            } else {
                appNode.volume = muted ? 0.0 : vol
            }
        }
    }
    
    public func getMute(bundleID: String) -> Bool {
        return isMuted[bundleID] ?? false
    }

    // EQ Bypass Control (EQ ON/OFF). Single write path — UI and engine code must
    // go through here so the observable dict, the live node, and the persisted
    // cache never drift apart.
    public func setEQBypass(bundleID: String, bypassed: Bool) {
        eqBypass[bundleID] = bypassed
        if let appNode = activeNodes[bundleID] {
            appNode.eqController.setBypass(bypassed)
        }
        if let cached = cachedAppSettings[bundleID] {
            cachedAppSettings[bundleID] = EQPresetData(bands: cached.bands, bypass: bypassed, volume: cached.volume)
        } else {
            // No curve yet — persist a flat curve carrying the bypass flag so the
            // toggle still survives a restart.
            cachedAppSettings[bundleID] = EQPresetData(bands: EQPresetData.flat.bands, bypass: bypassed, volume: getVolume(bundleID: bundleID))
        }
        persistAppSettings()
    }

    public func getEQBypass(bundleID: String) -> Bool {
        return eqBypass[bundleID] ?? false
    }

    private func snapshotEQSettings(bundleID: String, from appNode: AppAudioNode) {
        let data = appNode.eqController.getPresetData(volume: getVolume(bundleID: bundleID))
        cachedAppSettings[bundleID] = data
        eqBypass[bundleID] = data.bypass
        persistAppSettings()
    }

    // Fire-and-forget save, chained like PresetStore.pendingSave. Task.detached
    // (not Task) so the chain never touches the main actor —
    // flushAppSettingsBeforeTermination blocks the main thread waiting on it.
    private func persistAppSettings() {
        let snapshot = cachedAppSettings
        let previous = pendingSettingsSave
        pendingSettingsSave = Task.detached { [repository = appSettingsRepository] in
            await previous?.value
            do {
                try await repository.save(snapshot)
            } catch {
                print("AudioEngineManager: Failed to save app settings: \(error)")
            }
        }
    }

    /// Await the in-flight settings write (tests and async contexts).
    public func flushAppSettings() async {
        await pendingSettingsSave?.value
    }

    /// Bounded synchronous wait for the in-flight settings write. Safe from
    /// applicationWillTerminate: the save chain runs detached off the main actor,
    /// so blocking the main thread here cannot deadlock it.
    public func flushAppSettingsBeforeTermination() {
        guard let pending = pendingSettingsSave else { return }
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await pending.value
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2.0)
    }
    
    public func setNodeVolumeDirect(bundleID: String, volume: Float) {
        if let appNode = activeNodes[bundleID] {
            appNode.volume = volume
        }
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
            eqBypass[bundleID] = appPresetData.bypass

            if let appNode = activeNodes[bundleID] {
                appNode.eqController.applyPresetData(appPresetData)
                setVolume(bundleID: bundleID, volume: appPresetData.volume)
            }
        }
        persistAppSettings()
    }
    
    private func applyDefaultPreset() {
        // Launch-time seeding only: bundle IDs with persisted live state keep it —
        // the state saved at last quit wins over the default preset on relaunch.
        // No nodes are active this early, so there is nothing to apply live.
        guard let def = PresetStore.shared.defaultPreset else { return }
        for (bundleID, data) in def.appSettings where cachedAppSettings[bundleID] == nil {
            cachedAppSettings[bundleID] = data
            eqBypass[bundleID] = data.bypass
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
        AudioObjectAddPropertyListener(systemObjectID, &listAddress, deviceListProc, clientData)

        // System default output changed: follow only if user hasn't made a manual pick.
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: selectorDefaultOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListener(systemObjectID, &defaultAddress, defaultOutputProc, clientData)

        // Register Sleep, Wake, and AVAudioEngine configuration changes
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleEngineConfigurationChange(_:)), name: .AVAudioEngineConfigurationChange, object: nil)

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(handleSleep), name: NSWorkspace.willSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(handleWake), name: NSWorkspace.didWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(handleAppLaunched(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(handleAppTerminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        // Schedule repeating liveness watchdog timer (every 5 seconds) if not running under XCTest
        if NSClassFromString("XCTestCase") == nil {
            livenessTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.checkPIDsLiveness()
                }
            }
        }
    }

    @MainActor
    fileprivate func handleDeviceListChanged() {
        let prevID = self.selectedDeviceID
        self.refreshDevices()
        // If current device was removed (unplugged), fall back to system default.
        if !self.outputDevices.contains(where: { $0.deviceID == prevID }) {
            let fallback = self.getDefaultOutputDeviceID()
            if fallback != prevID {
                self._suppressFollowReset = true
                self.selectedDeviceID = fallback
                self._suppressFollowReset = false
                self.followsSystemDefault = true
            }
        }
        
        // Restore preferred device if it was missing and is now re-plugged
        let savedFollows = UserDefaults.standard.object(forKey: "followsSystemDefault") as? Bool ?? true
        let savedUID = UserDefaults.standard.string(forKey: "selectedDeviceUID")
        if !savedFollows, let uid = savedUID,
           let preferredDevice = self.outputDevices.first(where: { $0.uid == uid }) {
            if self.selectedDeviceID != preferredDevice.deviceID {
                print("AudioEngineManager: Restoring preferred device \(preferredDevice.name) (\(uid))")
                self._suppressFollowReset = true
                self._suppressSaveState = true
                self.selectedDeviceID = preferredDevice.deviceID
                self._suppressFollowReset = false
                self._suppressSaveState = false
            }
        }
        
        self.cleanupUnpluggedEngines()
    }

    @MainActor
    fileprivate func handleDefaultOutputChanged() {
        guard self.followsSystemDefault else {
            print("AudioEngineManager: System default changed but user has explicit pick — ignoring")
            return
        }
        let sysDefault = self.getDefaultOutputDeviceID()
        if self.selectedDeviceID != sysDefault {
            print("AudioEngineManager: Following system default device change → \(sysDefault)")
            self._suppressFollowReset = true
            self.selectedDeviceID = sysDefault
            self._suppressFollowReset = false
            self.followsSystemDefault = true
        }
    }

    @objc nonisolated private func handleSleep() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { [weak self] in
                self?.performSleep()
            }
        } else {
            DispatchQueue.main.sync { [weak self] in
                MainActor.assumeIsolated {
                    self?.performSleep()
                }
            }
        }
    }

    @MainActor
    private func performSleep() {
        print("AudioEngineManager: System going to sleep. Stopping engines...")
        for devEngine in self.engines.values {
            devEngine.engine.stop()
        }
        self.engines.removeAll()
    }
    
    @objc nonisolated private func handleWake() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { [weak self] in
                self?.performWake()
            }
        } else {
            DispatchQueue.main.sync { [weak self] in
                MainActor.assumeIsolated {
                    self?.performWake()
                }
            }
        }
    }

    @MainActor
    private func performWake() {
        print("AudioEngineManager: System woke up. Restoring audio routing...")
        self.refreshDevices()
        
        if self.followsSystemDefault {
            let sysDefault = self.getDefaultOutputDeviceID()
            if self.selectedDeviceID != sysDefault {
                self._suppressFollowReset = true
                self.selectedDeviceID = sysDefault
                self._suppressFollowReset = false
            }
        }
        
        self.recreateAllAppNodes()
    }
    
    private func recreateAllAppNodes() {
        let runningApps = activePIDs
        for bundleID in runningApps.keys {
            stopAppTapping(bundleID: bundleID)
        }
        for (bundleID, pid) in runningApps {
            startAppTapping(bundleID: bundleID, pid: pid)
        }
    }

    @objc nonisolated private func handleAppLaunched(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier else {
            return
        }
        let pid = app.processIdentifier

        if Thread.isMainThread {
            MainActor.assumeIsolated { [weak self] in
                self?.performAppLaunched(bundleID: bundleID, pid: pid)
            }
        } else {
            DispatchQueue.main.sync { [weak self] in
                MainActor.assumeIsolated {
                    self?.performAppLaunched(bundleID: bundleID, pid: pid)
                }
            }
        }
    }

    @MainActor
    private func performAppLaunched(bundleID: String, pid: pid_t) {
        if desiredTappedBundleIDs.contains(bundleID) {
            if let activePid = activePIDs[bundleID], activePid != pid {
                print("AudioEngineManager: Launched application \(bundleID) has different PID (\(pid)) than active PID (\(activePid)). Cleaning up old tap.")
                stopAppTapping(bundleID: bundleID)
            }
            print("AudioEngineManager: Launched application matches desired tapped ID: \(bundleID). Starting tap.")
            startAppTapping(bundleID: bundleID, pid: pid)
        }
    }

    @objc nonisolated private func handleAppTerminated(_ notification: Notification) {
        let bundleID: String?
        let pid: pid_t?
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            bundleID = app.bundleIdentifier
            pid = app.processIdentifier
        } else {
            bundleID = notification.userInfo?["bundleIdentifier"] as? String
            pid = notification.userInfo?["processIdentifier"] as? pid_t
        }

        guard let bundleID = bundleID else { return }

        if Thread.isMainThread {
            MainActor.assumeIsolated { [weak self] in
                self?.performAppTerminated(bundleID: bundleID, pid: pid)
            }
        } else {
            DispatchQueue.main.sync { [weak self] in
                MainActor.assumeIsolated {
                    self?.performAppTerminated(bundleID: bundleID, pid: pid)
                }
            }
        }
    }

    @MainActor
    private func performAppTerminated(bundleID: String, pid: pid_t?) {
        if let terminatingPid = pid {
            if activePIDs[bundleID] == terminatingPid {
                print("AudioEngineManager: Terminated application detected: \(bundleID) (PID: \(terminatingPid)). Stopping tap.")
                stopAppTapping(bundleID: bundleID)
            }
        } else if activeNodes[bundleID] != nil || activePIDs[bundleID] != nil {
            print("AudioEngineManager: Terminated application detected: \(bundleID) (unknown PID). Stopping tap.")
            stopAppTapping(bundleID: bundleID)
        }
    }

    @MainActor
    private func checkPIDsLiveness() {
        var toStop: [String] = []
        for (bundleID, pid) in activePIDs {
            if Darwin.kill(pid, 0) == -1 && Darwin.errno == ESRCH {
                print("AudioEngineManager: Liveness check failed for \(bundleID) (PID: \(pid)). Stopping tap.")
                toStop.append(bundleID)
            }
        }
        for bundleID in toStop {
            stopAppTapping(bundleID: bundleID)
        }
    }

    @MainActor
    func checkTappedProcessesLiveness() {
        for (bundleID, pid) in activePIDs {
            let killResult = Darwin.kill(pid, 0)
            let isEsrch = (killResult == -1 && Darwin.errno == ESRCH)
            
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            let matchingApp = apps.first { $0.processIdentifier == pid }
            let isTerminated = matchingApp?.isTerminated ?? false
            let isNSRunningAppDead = !apps.isEmpty && (matchingApp == nil || isTerminated)
            
            if isEsrch || isNSRunningAppDead {
                print("AudioEngineManager: Watchdog detected dead process for \(bundleID) (PID: \(pid)). Stopping tap.")
                stopAppTapping(bundleID: bundleID)
            }
        }
    }

    @MainActor
    internal func checkLiveness() {
        checkTappedProcessesLiveness()
    }

    @MainActor
    public func teardown() {
        livenessTimer?.invalidate()
        livenessTimer = nil
        
        let keys = Array(activeNodes.keys)
        for bundleID in keys {
            stopAppTapping(bundleID: bundleID)
        }
    }
    
    @objc nonisolated private func handleEngineConfigurationChange(_ notification: Notification) {
        nonisolated(unsafe) let changedEngine = notification.object as? AVAudioEngine
        if Thread.isMainThread {
            MainActor.assumeIsolated { [weak self] in
                self?.performEngineConfigurationChange(changedEngine: changedEngine)
            }
        } else {
            DispatchQueue.main.sync { [weak self] in
                MainActor.assumeIsolated {
                    self?.performEngineConfigurationChange(changedEngine: changedEngine)
                }
            }
        }
    }

    @MainActor
    private func performEngineConfigurationChange(changedEngine: AVAudioEngine?) {
        guard let changedEngine = changedEngine else { return }
        guard let deviceID = self.engines.first(where: { $0.value.engine === changedEngine })?.key else { return }
        
        print("AudioEngineManager: Configuration change detected for engine on device \(deviceID)")
        
        self.deviceIDsChangingConfig.insert(deviceID)
        defer {
            self.deviceIDsChangingConfig.remove(deviceID)
            self.cleanupIdleEngines()
        }
        
        let appsOnThisDevice = self.appBusRoutes.filter { $0.value.deviceID == deviceID }.map { $0.key }
        var pidsToRestart: [String: pid_t] = [:]
        for bundleID in appsOnThisDevice {
            if let pid = self.activePIDs[bundleID] {
                pidsToRestart[bundleID] = pid
            }
            self.stopAppTapping(bundleID: bundleID)
        }
        
        if let devEngine = self.engines[deviceID] {
            devEngine.engine.stop()
            devEngine.nextBus = 0
            devEngine.freeBuses = []
            
            if devEngine.deviceID != kAudioObjectUnknown, let outputUnit = devEngine.engine.outputNode.audioUnit {
                var devID = devEngine.deviceID
                AudioUnitSetProperty(
                    outputUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &devID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
            }
            
            do {
                try devEngine.engine.start()
                print("AudioEngineManager: Restarted engine for device \(deviceID) after config change")
            } catch {
                print("AudioEngineManager: Failed to restart engine for device \(deviceID): \(error)")
            }
        }
        
        for (bundleID, pid) in pidsToRestart {
            self.startAppTapping(bundleID: bundleID, pid: pid)
        }
    }
    
    private func cleanupUnpluggedEngines() {
        let validIDs = Set(outputDevices.map { $0.deviceID })
        let enginesToClean = engines.keys.filter { !validIDs.contains($0) && $0 != kAudioObjectUnknown }
        
        for devID in enginesToClean {
            print("AudioEngineManager: Cleaning up unplugged engine for device \(devID)")
            if let devEngine = engines.removeValue(forKey: devID) {
                devEngine.engine.stop()
            }
            let appsOnThisDevice = appBusRoutes.filter { $0.value.deviceID == devID }.map { $0.key }
            for bundleID in appsOnThisDevice {
                setAppOutputDevice(bundleID: bundleID, deviceID: kAudioObjectUnknown)
            }
        }
        
        // Scan appOutputDevices for unplugged devices (both active and inactive apps)
        for (bundleID, devID) in appOutputDevices {
            if devID != kAudioObjectUnknown && !validIDs.contains(devID) {
                print("AudioEngineManager: Resetting output device for \(bundleID) because device \(devID) was unplugged")
                appOutputDevices[bundleID] = kAudioObjectUnknown
            }
        }
    }
    
    private func cleanupIdleEngines() {
        let activeDeviceIDs = Set(appBusRoutes.values.map { $0.deviceID })
        let idleEngines = engines.keys.filter { devID in
            devID != selectedDeviceID && !activeDeviceIDs.contains(devID) && !deviceIDsChangingConfig.contains(devID)
        }
        
        for devID in idleEngines {
            print("AudioEngineManager: Cleaning up idle engine for device \(devID)")
            if let devEngine = engines.removeValue(forKey: devID) {
                devEngine.engine.stop()
            }
        }
    }
}

#if DEBUG
@available(macOS 14.2, *)
extension AudioEngineManager {
    public func testExposeCleanupUnpluggedEngines() {
        self.cleanupUnpluggedEngines()
    }
    
    public func testExposeCleanupIdleEngines() {
        self.cleanupIdleEngines()
    }
    
    public func testExposeDeviceIDsChangingConfig() -> Set<AudioDeviceID> {
        return self.deviceIDsChangingConfig
    }
    
    public func testExposeGetEngine(for deviceID: AudioDeviceID) -> AVAudioEngine {
        return self.getEngine(for: deviceID).engine
    }
    
    public func testExposeEnginesCount() -> Int {
        return self.engines.count
    }
    
    public func testExposeSetDeviceChangingConfig(_ deviceID: AudioDeviceID, isChanging: Bool) {
        if isChanging {
            self.deviceIDsChangingConfig.insert(deviceID)
        } else {
            self.deviceIDsChangingConfig.remove(deviceID)
        }
    }
    
    public func testExposeCheckLiveness() {
        self.checkLiveness()
    }
    
    public func testExposeCheckPIDsLiveness() {
        self.checkPIDsLiveness()
    }
}
#endif
