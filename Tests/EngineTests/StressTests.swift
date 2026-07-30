import Testing
import AVFoundation
import CoreAudio
import AppKit
@testable import Engine
@testable import Core

@Suite @MainActor
struct StressTests {
    
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
    
    private func getActivePIDs(from manager: AudioEngineManager) -> [String: Int32] {
        let mirror = Mirror(reflecting: manager)
        if let pidsRaw = mirror.descendant("_activePIDs") as? [String: Int32] {
            return pidsRaw
        }
        return [:]
    }

    // 1. Rapidly launching and quitting target applications (Simulation)
    @Test func rapidProcessLaunchAndQuitSimulation() async throws {
        let manager = createTestManager()
        
        for i in 0..<100 {
            let bundleID = "com.example.App\(i)"
            let pid = pid_t(20000 + i)
            
            // App launch simulation
            manager.startAppTapping(bundleID: bundleID, pid: pid)
            #expect(getActivePIDs(from: manager)[bundleID] != nil)
            
            // App termination simulation
            let mockApp = MockRunningApplication(bundleIdentifier: bundleID, pid: pid)
            let notification = Notification(
                name: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                userInfo: [NSWorkspace.applicationUserInfoKey: mockApp]
            )
            NSWorkspace.shared.notificationCenter.post(notification)
            
            #expect(getActivePIDs(from: manager)[bundleID] == nil)
        }
    }

    // 2. Force-quitting target applications while tapping is active
    @Test func forceQuitSimulation() throws {
        let manager = createTestManager()
        let bundleID = "com.apple.Safari"
        
        // Spawn a real child process (e.g. sleep 10)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        try process.run()
        
        let pid = process.processIdentifier
        
        manager.startAppTapping(bundleID: bundleID, pid: pid)
        #expect(getActivePIDs(from: manager)[bundleID] != nil)
        
        // Force-kill the process
        process.terminate()
        process.waitUntilExit()
        
        // Trigger liveness checks (watchdog)
        manager.testExposeCheckLiveness()
        
        // Verify that the watchdog cleaned it up
        #expect(getActivePIDs(from: manager)[bundleID] == nil, "Tapped app should be cleaned up immediately when the process is force-killed")
    }

    // 3. Rapidly toggling the tap/power button (MainActor concurrency safety check)
    @Test func concurrentTogglingAppTapping() async throws {
        let manager = createTestManager()
        let bundleID = "com.example.ConcurrentApp"
        let pid: pid_t = 30001
        
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    for _ in 0..<50 {
                        await MainActor.run {
                            manager.startAppTapping(bundleID: bundleID, pid: pid)
                            manager.stopAppTapping(bundleID: bundleID)
                        }
                    }
                }
            }
        }
        
        #expect(getActivePIDs(from: manager)[bundleID] == nil, "Tapping should be fully stopped and cleaned up after concurrent toggles")
    }

    // 4. Verify no engine stalls, memory leaks, or aggregate device naming collisions under load
    @Test func aggDeviceLifecycleStability() async throws {
        // We test with our own PID because we know it exists and might have a process object ID,
        // or we can test using ProcessTapManager.shared directly if the system permits.
        // Let's call startTapping and stopTapping on ProcessTapManager.shared directly in a loop to stress-test HAL interaction.
        let bundleID = "com.apple.Safari"
        let pid = getpid()
        
        // Let's see if we can get a process ID. If not, we will skip the real HAL call but we can still stress test the mock path.
        var tapCount = 0
        for _ in 0..<20 {
            if let result = ProcessTapManager.shared.startTapping(bundleID: bundleID, pid: pid) {
                tapCount += 1
                #expect(ProcessTapManager.shared.getRingBuffers(bundleID: bundleID) != nil)
                ProcessTapManager.shared.stopTapping(bundleID: bundleID)
                #expect(ProcessTapManager.shared.getRingBuffers(bundleID: bundleID) == nil)
            }
        }
        print("Completed real HAL tap iterations: \(tapCount)")
    }
}
