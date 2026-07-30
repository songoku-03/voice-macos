import Testing
import AVFoundation
import CoreAudio
import AppKit
@testable import Engine
@testable import Core

@Suite(.serialized) @MainActor
struct AudioEngineIntegrationTests {
    
    private func createTestManager() -> AudioEngineManager {
        let manager = AudioEngineManager()
        #if DEBUG
        manager.tapProvider = { _, _ in
            let dummyBuffer = RingBuffer(capacity: 64 * 1024)
            var dummyASBD = AudioStreamBasicDescription()
            dummyASBD.mSampleRate = 48000.0
            dummyASBD.mFormatID = kAudioFormatLinearPCM
            dummyASBD.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian
            dummyASBD.mBytesPerPacket = 8
            dummyASBD.mFramesPerPacket = 1
            dummyASBD.mBytesPerFrame = 8
            dummyASBD.mChannelsPerFrame = 2
            dummyASBD.mBitsPerChannel = 32
            return ([dummyBuffer], dummyASBD)
        }
        #endif
        return manager
    }
    
    @Test func offlineRenderingFlow() throws {
        let sampleRate: Double = 48000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        
        let engine = AVAudioEngine()
        
        // 1. Enable manual rendering mode (offline)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        
        // 2. Initialize RingBuffer and fill with a test signal (Sine wave at 440Hz)
        let ringBuffer = RingBuffer(capacity: 64 * 1024)
        let sineFreq: Double = 440.0
        let framesCount = 2048
        
        // Prepare interleaved float sine wave
        var sineData = [Float](repeating: 0, count: framesCount * 2)
        for i in 0..<framesCount {
            let t = Double(i) / sampleRate
            let val = Float(sin(2.0 * .pi * sineFreq * t))
            sineData[i * 2] = val     // Left
            sineData[i * 2 + 1] = val // Right
        }
        
        // Write to ring buffer
        let bytesWritten = sineData.withUnsafeBufferPointer { ptr in
            ringBuffer.write(ptr.baseAddress!, byteCount: framesCount * 2 * MemoryLayout<Float>.size)
        }
        #expect(bytesWritten == framesCount * 2 * MemoryLayout<Float>.size)
        
        // 3. Create AppAudioNode (input: 48000Hz stereo interleaved float)
        var tapASBD = AudioStreamBasicDescription()
        tapASBD.mSampleRate = sampleRate
        tapASBD.mFormatID = kAudioFormatLinearPCM
        tapASBD.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian // interleaved
        tapASBD.mBytesPerPacket = 8
        tapASBD.mFramesPerPacket = 1
        tapASBD.mBytesPerFrame = 8
        tapASBD.mChannelsPerFrame = 2
        tapASBD.mBitsPerChannel = 32
        
        guard let appNode = AppAudioNode(ringBuffers: [ringBuffer], sourceFormat: tapASBD, engineFormat: format) else {
            Issue.record("Failed to create AppAudioNode")
            return
        }
        
        // 4. Attach nodes and connect
        engine.attach(appNode.sourceNode)
        engine.attach(appNode.eqNode)
        
        engine.connect(appNode.sourceNode, to: appNode.eqNode, format: format)
        engine.connect(appNode.eqNode, to: engine.mainMixerNode, format: format)
        
        // Ensure volume is full (1.0)
        appNode.volume = 1.0
        
        // 5. Start engine
        try engine.start()
        
        // 6. Prepare rendering destination buffer
        let renderBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        
        // 7. Render 512 frames offline
        let status = try engine.renderOffline(512, to: renderBuffer)
        #expect(status == .success)
        #expect(renderBuffer.frameLength == 512)
        
        // 8. Analyze render buffer (calculate Root Mean Square - RMS)
        var sumSquares: Float = 0.0
        let channelData = renderBuffer.floatChannelData!
        let leftChannel = channelData[0]
        let rightChannel = channelData[1]
        
        for i in 0..<512 {
            sumSquares += leftChannel[i] * leftChannel[i]
            sumSquares += rightChannel[i] * rightChannel[i]
        }
        let rms = sqrt(sumSquares / Float(512 * 2))
        
        print("AudioEngineIntegrationTests: RMS with volume 1.0 = \(rms)")
        #expect(rms > 0.001, "Audio output is silent, but should contain sound samples!")
        
        // 9. Test Volume Control (Set volume to 0.0 / mute)
        appNode.volume = 0.0
        
        // Render next 512 frames
        let renderBufferMuted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        let statusMuted = try engine.renderOffline(512, to: renderBufferMuted)
        #expect(statusMuted == .success)
        
        var sumSquaresMuted: Float = 0.0
        let channelDataMuted = renderBufferMuted.floatChannelData!
        let leftMuted = channelDataMuted[0]
        let rightMuted = channelDataMuted[1]
        
        for i in 0..<512 {
            sumSquaresMuted += leftMuted[i] * leftMuted[i]
            sumSquaresMuted += rightMuted[i] * rightMuted[i]
        }
        let rmsMuted = sqrt(sumSquaresMuted / Float(512 * 2))
        
        print("AudioEngineIntegrationTests: RMS with volume 0.0 = \(rmsMuted)")
        #expect(rmsMuted < 0.00001, "Audio output should be silent when volume is 0.0!")
        
        // Stop engine
        engine.stop()
    }

    @Test func statePersistence() throws {
        UserDefaults.standard.removeObject(forKey: "selectedDeviceUID")
        let manager = AudioEngineManager()
        
        // Set explicitly to false
        manager.followsSystemDefault = false
        #expect(!UserDefaults.standard.bool(forKey: "followsSystemDefault"))
        
        // Test that setting selectedDeviceID saves the UID if it matches a known device
        if let firstDevice = manager.outputDevices.first {
            manager.selectedDeviceID = kAudioObjectUnknown
            manager.selectedDeviceID = firstDevice.deviceID
            #expect(UserDefaults.standard.string(forKey: "selectedDeviceUID") == firstDevice.uid)
            #expect(!manager.followsSystemDefault)
        }
    }
    
    @Test func sleepWakeNotifications() throws {
        let nc = NSWorkspace.shared.notificationCenter
        
        // Post sleep notification to test notification handling path
        nc.post(name: NSWorkspace.willSleepNotification, object: nil)
        
        // Post wake notification
        nc.post(name: NSWorkspace.didWakeNotification, object: nil)
    }
    
    @Test func engineConfigurationChangeNotification() throws {
        let mockEngine = AVAudioEngine()
        
        // Post the configuration change notification
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: mockEngine
        )
    }

    @Test func invalidDeviceUIDPersistence() throws {
        // Set invalid device UID in UserDefaults
        UserDefaults.standard.set(false, forKey: "followsSystemDefault")
        UserDefaults.standard.set("NonExistentDeviceUID_12345", forKey: "selectedDeviceUID")
        
        let manager = AudioEngineManager()
        
        // It should fallback to the system default device
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sysDefault = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &sysDefault)
        #expect(status == noErr)
        #expect(manager.selectedDeviceID == sysDefault)
        
        // But followsSystemDefault should remain false (since savedFollows was false)
        #expect(!manager.followsSystemDefault)
        
        // And now selectedDeviceUID in UserDefaults should not be overwritten
        #expect(UserDefaults.standard.string(forKey: "selectedDeviceUID") == "NonExistentDeviceUID_12345")
    }
    
    private func getEngineDeviceIDs(from manager: AudioEngineManager) -> Set<AudioDeviceID> {
        let mirror = Mirror(reflecting: manager)
        guard let enginesRaw = mirror.descendant("engines") else { return [] }
        let enginesMirror = Mirror(reflecting: enginesRaw)
        var deviceIDs = Set<AudioDeviceID>()
        for child in enginesMirror.children {
            let childMirror = Mirror(reflecting: child.value)
            let elements = childMirror.children.map { $0.value }
            if elements.count == 2, let key = elements[0] as? AudioDeviceID {
                deviceIDs.insert(key)
            }
        }
        return deviceIDs
    }
    
    private func getActivePIDs(from manager: AudioEngineManager) -> [String: Int32] {
        let mirror = Mirror(reflecting: manager)
        if let pidsRaw = mirror.descendant("_activePIDs") as? [String: Int32] {
            return pidsRaw
        }
        return [:]
    }

    @Test func sleepWakeStateRestoration() throws {
        let manager = createTestManager()
        
        // Populate activePIDs by calling startAppTapping
        manager.startAppTapping(bundleID: "com.apple.Safari", pid: 99999)
        
        let activePIDs = getActivePIDs(from: manager)
        #expect(activePIDs["com.apple.Safari"] == 99999)
        
        // Post sleep notification to test notification handling path
        let nc = NSWorkspace.shared.notificationCenter
        nc.post(name: NSWorkspace.willSleepNotification, object: nil)
        
        // Verify engines map is cleared on sleep
        let engines = getEngineDeviceIDs(from: manager)
        #expect(engines.isEmpty)
        
        // Post wake notification
        nc.post(name: NSWorkspace.didWakeNotification, object: nil)
        
        // Verify activePIDs is restored/repopulated after wake
        let postWakePIDs = getActivePIDs(from: manager)
        #expect(postWakePIDs["com.apple.Safari"] == 99999)
    }
    
    @Test func rapidSleepWakeCycles() throws {
        let manager = createTestManager()
        let nc = NSWorkspace.shared.notificationCenter
        
        manager.startAppTapping(bundleID: "com.apple.Safari", pid: 99999)
        
        for _ in 0..<10 {
            nc.post(name: NSWorkspace.willSleepNotification, object: nil)
            nc.post(name: NSWorkspace.didWakeNotification, object: nil)
        }
        
        let activePIDs = getActivePIDs(from: manager)
        #expect(activePIDs["com.apple.Safari"] == 99999)
    }
    
    @Test func activePIDsCleanupOnTapFailure() throws {
        let manager = AudioEngineManager()
        // Try tapping a non-existent app bundle ID, which should fail
        manager.startAppTapping(bundleID: "com.example.NonExistentApp", pid: 12345)
        
        let pids = getActivePIDs(from: manager)
        #expect(pids["com.example.NonExistentApp"] == nil, "The bundleID should not be present in activePIDs after tap failure")
    }
    
    @Test func cleanupUnpluggedEnginesResetsAppOutputDevices() throws {
        let manager = AudioEngineManager()
        
        let unpluggedDeviceID: AudioDeviceID = 9999
        
        // Set an app output device to this unplugged device
        manager.setAppOutputDevice(bundleID: "com.example.InactiveApp", deviceID: unpluggedDeviceID)
        #expect(manager.getAppOutputDevice(bundleID: "com.example.InactiveApp") == unpluggedDeviceID)
        
        // Trigger cleanup
        manager.testExposeCleanupUnpluggedEngines()
        
        // It should reset to kAudioObjectUnknown
        #expect(manager.getAppOutputDevice(bundleID: "com.example.InactiveApp") == kAudioObjectUnknown)
    }
    
    @Test func cleanupIdleEnginesBypassesConfiguringDevice() throws {
        let manager = AudioEngineManager()
        
        let deviceID: AudioDeviceID = 8888
        
        // Create an engine for the device (it will be in engines map)
        _ = manager.testExposeGetEngine(for: deviceID)
        let initialCount = manager.testExposeEnginesCount()
        #expect(initialCount >= 2)
        
        // Ordinarily, deviceID is not selected and has no active routes, so it will be cleaned up
        manager.testExposeCleanupIdleEngines()
        #expect(manager.testExposeEnginesCount() == initialCount - 1)
        
        // Add it back
        _ = manager.testExposeGetEngine(for: deviceID)
        #expect(manager.testExposeEnginesCount() == initialCount)
        
        // Set configuration change in progress for deviceID
        manager.testExposeSetDeviceChangingConfig(deviceID, isChanging: true)
        
        // Attempt clean up - it should NOT clean it up
        manager.testExposeCleanupIdleEngines()
        #expect(manager.testExposeEnginesCount() == initialCount)
        
        // Stop configuration change and clean up - now it should clean it up
        manager.testExposeSetDeviceChangingConfig(deviceID, isChanging: false)
        manager.testExposeCleanupIdleEngines()
        #expect(manager.testExposeEnginesCount() == initialCount - 1)
    }

    @Test func newAppTappedDuringBreakIsDucked() async throws {
        let manager = createTestManager()
        let btm = BreakTimerManager.shared
        
        // Save current configurations to restore later
        let originalStudy = btm.studyDuration
        let originalBreak = btm.breakDuration
        let originalManager = btm.audioEngineManager
        
        defer {
            btm.stop()
            btm.studyDuration = originalStudy
            btm.breakDuration = originalBreak
            btm.audioEngineManager = originalManager
        }
        
        btm.audioEngineManager = manager
        
        // Put BreakTimerManager into breaking phase
        btm.stop()
        btm.studyDuration = 0.001
        btm.breakDuration = 60.0
        
        btm.start()
        
        // Wait for the timer to tick and transition through warning to breaking.
        // It takes at least 11-12 seconds because warningThreshold is 10 seconds.
        // We will wait up to 15 seconds.
        let startTime = Date()
        while btm.phase != .breaking {
            if Date().timeIntervalSince(startTime) > 15 {
                Issue.record("Failed to transition to breaking phase. Current phase: \(btm.phase)")
                break
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        
        #expect(btm.phase == .breaking, "Should be in breaking phase")
        
        // Now tap a new app Safari (which should succeed/simulate tapping)
        manager.startAppTapping(bundleID: "com.apple.Safari", pid: ProcessInfo.processInfo.processIdentifier)
        
        // Verify if the volume is ducked.
        let volume = manager.activeNodes["com.apple.Safari"]?.volume ?? 0
        let expectedDucked = manager.getVolume(bundleID: "com.apple.Safari") * 0.1
        #expect(abs(volume - expectedDucked) < 0.001, "Newly tapped app volume should be ducked during break")
    }

    @Test func repeatedTappingDuringBreakRetainsOriginalPreBreakVolume() async throws {
        let manager = AudioEngineManager.shared
        let btm = BreakTimerManager.shared
        
        let originalStudy = btm.studyDuration
        let originalBreak = btm.breakDuration
        let originalVolume = manager.getVolume(bundleID: "com.apple.Safari")
        let originalManager = btm.audioEngineManager
        
        #if DEBUG
        manager.tapProvider = { _, _ in
            let dummyBuffer = RingBuffer(capacity: 64 * 1024)
            var dummyASBD = AudioStreamBasicDescription()
            dummyASBD.mSampleRate = 48000.0
            dummyASBD.mFormatID = kAudioFormatLinearPCM
            dummyASBD.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian
            dummyASBD.mBytesPerPacket = 8
            dummyASBD.mFramesPerPacket = 1
            dummyASBD.mBytesPerFrame = 8
            dummyASBD.mChannelsPerFrame = 2
            dummyASBD.mBitsPerChannel = 32
            return ([dummyBuffer], dummyASBD)
        }
        #endif
        
        defer {
            #if DEBUG
            manager.tapProvider = nil
            #endif
            manager.stopAppTapping(bundleID: "com.apple.Safari")
            manager.setVolume(bundleID: "com.apple.Safari", volume: originalVolume)
            btm.stop()
            btm.studyDuration = originalStudy
            btm.breakDuration = originalBreak
            btm.audioEngineManager = originalManager
        }
        
        btm.audioEngineManager = manager
        
        manager.startAppTapping(bundleID: "com.apple.Safari", pid: ProcessInfo.processInfo.processIdentifier)
        manager.setVolume(bundleID: "com.apple.Safari", volume: 0.8)
        
        btm.stop()
        btm.studyDuration = 0.001
        btm.breakDuration = 60.0
        btm.start()
        
        let startTime = Date()
        while btm.phase != .breaking {
            if Date().timeIntervalSince(startTime) > 15 {
                Issue.record("Failed to transition to breaking phase. Current phase: \(btm.phase)")
                break
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        
        #expect(btm.phase == .breaking, "Should be in breaking phase")
        let duckedVolume = manager.activeNodes["com.apple.Safari"]?.volume ?? 0
        #expect(abs(duckedVolume - 0.08) < 0.001, "Volume should be ducked")
        
        manager.stopAppTapping(bundleID: "com.apple.Safari")
        manager.startAppTapping(bundleID: "com.apple.Safari", pid: ProcessInfo.processInfo.processIdentifier)
        
        btm.stop()
        
        let restoredVolume = manager.getVolume(bundleID: "com.apple.Safari")
        #expect(abs(restoredVolume - 0.8) < 0.001, "Volume should be restored to pre-break level 0.8")
    }

    @Test func livenessCheckRemovesInactivePIDs() throws {
        let manager = createTestManager()
        
        let dummyPID: pid_t = 999999
        manager.startAppTapping(bundleID: "com.apple.Safari", pid: dummyPID)
        
        let pidsBefore = getActivePIDs(from: manager)
        #expect(pidsBefore["com.apple.Safari"] == dummyPID)
        
        manager.testExposeCheckLiveness()
        
        let pidsAfter = getActivePIDs(from: manager)
        #expect(pidsAfter["com.apple.Safari"] == nil, "Inactive PID should be cleaned up by liveness check")
    }

    @Test func appTerminationNotificationCleansUpTap() throws {
        let manager = createTestManager()
        
        manager.startAppTapping(bundleID: "com.apple.Safari", pid: 999999)
        let pidsBefore = getActivePIDs(from: manager)
        #expect(pidsBefore["com.apple.Safari"] != nil)
        
        let mockApp = MockRunningApplication(bundleIdentifier: "com.apple.Safari")
        let notification = Notification(
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: mockApp]
        )
        
        NSWorkspace.shared.notificationCenter.post(notification)
        
        let pidsAfter = getActivePIDs(from: manager)
        #expect(pidsAfter["com.apple.Safari"] == nil, "Tapped app should be cleaned up on didTerminateApplicationNotification")
    }

    @Test func appTerminationCleanup() throws {
        let manager = createTestManager()
        
        // 1. Verify workspace notification cleanup flow
        manager.startAppTapping(bundleID: "com.apple.Safari", pid: 999999)
        #expect(getActivePIDs(from: manager)["com.apple.Safari"] != nil)
        
        let mockApp = MockRunningApplication(bundleIdentifier: "com.apple.Safari")
        let notification = Notification(
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: mockApp]
        )
        NSWorkspace.shared.notificationCenter.post(notification)
        #expect(getActivePIDs(from: manager)["com.apple.Safari"] == nil, "Should clean up on didTerminateApplicationNotification")
        
        // 2. Verify watchdog liveness checks flow
        let dummyPID: pid_t = 999999
        manager.startAppTapping(bundleID: "com.apple.Safari", pid: dummyPID)
        #expect(getActivePIDs(from: manager)["com.apple.Safari"] == dummyPID)
        
        // Trigger liveness check
        manager.checkTappedProcessesLiveness()
        
        #expect(getActivePIDs(from: manager)["com.apple.Safari"] == nil, "Watchdog should clean up dead process")
    }

    @Test func teardownCleansUpAllNodesAndTimer() throws {
        let manager = createTestManager()
        
        manager.startAppTapping(bundleID: "com.apple.Safari", pid: 999999)
        manager.startAppTapping(bundleID: "com.apple.Finder", pid: 98766)
        
        let pidsBefore = getActivePIDs(from: manager)
        #expect(pidsBefore.count == 2)
        
        manager.teardown()
        
        let pidsAfter = getActivePIDs(from: manager)
        #expect(pidsAfter.count == 0, "All nodes should be cleaned up after teardown")
    }
}

@available(macOS 14.2, *)
class MockRunningApplication: NSRunningApplication {
    private let mockBundleID: String
    private let mockPID: pid_t
    
    init(bundleIdentifier: String, pid: pid_t = 999999) {
        self.mockBundleID = bundleIdentifier
        self.mockPID = pid
        super.init()
    }
    
    override var bundleIdentifier: String? {
        return mockBundleID
    }
    
    override var processIdentifier: pid_t {
        return mockPID
    }
}
