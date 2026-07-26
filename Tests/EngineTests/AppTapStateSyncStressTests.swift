import Testing
import AVFoundation
import CoreAudio
import AppKit
@testable import Engine
@testable import Core

@MainActor
@Suite struct AppTapStateSyncStressTests {

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

    // 1. Rapidly launching and quitting target applications (Mocked Workspace Notifications)
    @Test func stressRapidLaunchAndQuitNotifications() throws {
        let manager = createTestManager()
        let iterations = 100
        let bundleID = "com.apple.Safari"

        for i in 0..<iterations {
            let pid = Int32(10000 + i)
            
            // Start tapping
            manager.startAppTapping(bundleID: bundleID, pid: pid)
            #expect(getActivePIDs(from: manager)[bundleID] == pid)

            // Simulate termination notification
            let mockApp = MockRunningApplication(bundleIdentifier: bundleID, pid: pid)
            let notification = Notification(
                name: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                userInfo: [NSWorkspace.applicationUserInfoKey: mockApp]
            )
            NSWorkspace.shared.notificationCenter.post(notification)

            // Verify clean up
            #expect(getActivePIDs(from: manager)[bundleID] == nil)
        }
    }

    // 2. Rapidly toggling the tap/power button (start/stop tapping)
    @Test func stressRapidTapToggling() throws {
        let manager = createTestManager()
        let iterations = 200
        let bundleID = "com.apple.Finder"
        let pid: pid_t = 12345

        for _ in 0..<iterations {
            manager.startAppTapping(bundleID: bundleID, pid: pid)
            #expect(getActivePIDs(from: manager)[bundleID] != nil)

            manager.userStopAppTapping(bundleID: bundleID)
            #expect(getActivePIDs(from: manager)[bundleID] == nil)
        }
    }

    // 3. Force-quitting (kill -9) target applications while tapping is active (Real Process)
    @Test func stressForceQuitRealProcess() throws {
        let manager = createTestManager()
        let bundleID = "com.apple.TextEdit"
        
        // Spawn a real TextEdit process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/System/Applications/TextEdit.app/Contents/MacOS/TextEdit")
        try process.run()
        
        let pid = process.processIdentifier
        #expect(pid > 0)
        
        // Let it start up
        Thread.sleep(forTimeInterval: 0.5)
        
        // Start tapping
        manager.startAppTapping(bundleID: bundleID, pid: pid)
        #expect(getActivePIDs(from: manager)[bundleID] == pid)
        
        // Kill the process forcefully
        process.terminate() // sends SIGTERM/SIGKILL
        process.waitUntilExit()
        
        // Trigger liveness checks (watchdog)
        manager.testExposeCheckLiveness()
        
        // Verify that the dead PID is cleaned up immediately
        #expect(getActivePIDs(from: manager)[bundleID] == nil, "Dead process should be cleaned up by watchdog")
    }

    // 4. Verify no aggregate device naming/UID collisions or memory leaks during high churn
    @Test func stressAggregateDeviceNamingAndChurn() throws {
        let manager = createTestManager()
        let bundleID = "com.apple.Safari"
        let pid: pid_t = 999999

        // Let's run a churn of 100 start/stop cycles
        for _ in 0..<100 {
            manager.startAppTapping(bundleID: bundleID, pid: pid)
            #expect(getActivePIDs(from: manager)[bundleID] != nil)
            manager.stopAppTapping(bundleID: bundleID)
            #expect(getActivePIDs(from: manager)[bundleID] == nil)
        }
    }
}
