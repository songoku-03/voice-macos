import Testing
import AVFoundation
import CoreAudio
import AppKit
@testable import Engine
@testable import Core

@MainActor
@Suite struct AppTapStateSyncTests {
    
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

    // 1. App termination notification clean up test
    @Test func appTerminationNotificationCleansUpTap() throws {
        let manager = createTestManager()
        
        manager.startAppTapping(bundleID: "com.apple.Safari", pid: 999999)
        #expect(getActivePIDs(from: manager)["com.apple.Safari"] != nil)
        
        // Mock using NSRunningApplication
        let mockApp = MockRunningApplication(bundleIdentifier: "com.apple.Safari")
        let notificationApp = Notification(
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: mockApp]
        )
        
        NSWorkspace.shared.notificationCenter.post(notificationApp)
        
        #expect(getActivePIDs(from: manager)["com.apple.Safari"] == nil, "Tapped app should be cleaned up on didTerminateApplicationNotification")
        
        // Now test the fallback bundleIdentifier string
        manager.startAppTapping(bundleID: "com.apple.Finder", pid: 98766)
        #expect(getActivePIDs(from: manager)["com.apple.Finder"] != nil)
        
        let notificationFallback = Notification(
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            userInfo: ["bundleIdentifier": "com.apple.Finder"]
        )
        
        NSWorkspace.shared.notificationCenter.post(notificationFallback)
        
        #expect(getActivePIDs(from: manager)["com.apple.Finder"] == nil, "Tapped app should be cleaned up using fallback bundleIdentifier key")
    }
    
    // 2. PID liveness check clean up test
    @Test func pIDLivenessCheckCleansUpDeadPIDs() throws {
        let manager = createTestManager()
        
        // Start tapping for a fake/dead PID (e.g. 99999)
        manager.startAppTapping(bundleID: "com.apple.Safari", pid: 99999)
        #expect(getActivePIDs(from: manager)["com.apple.Safari"] != nil)
        
        // Run the exposed checkPIDsLiveness method
        manager.testExposeCheckPIDsLiveness()
        
        // Verify that Safari tap was removed because PID 99999 is dead
        #expect(getActivePIDs(from: manager)["com.apple.Safari"] == nil, "Dead PID should be cleaned up by liveness check")
        
        // Start tapping for a live PID (e.g., our own PID)
        let ownPID = getpid()
        manager.startAppTapping(bundleID: "com.apple.Safari", pid: ownPID)
        #expect(getActivePIDs(from: manager)["com.apple.Safari"] != nil)
        
        // Run liveness check
        manager.testExposeCheckPIDsLiveness()
        
        // Verify that Safari tap remains because our own PID is alive
        #expect(getActivePIDs(from: manager)["com.apple.Safari"] != nil, "Live PID should not be cleaned up by liveness check")
    }
}
