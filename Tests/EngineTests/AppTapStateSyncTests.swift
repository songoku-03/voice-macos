import XCTest
import AVFoundation
import CoreAudio
import AppKit
@testable import Engine
@testable import Core

@available(macOS 14.2, *)
@MainActor
final class AppTapStateSyncTests: XCTestCase {
    
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
    func testAppTerminationNotificationCleansUpTap() throws {
        let manager = createTestManager()
        
        manager.startAppTapping(bundleID: "com.apple.Safari", pid: 999999)
        XCTAssertNotNil(getActivePIDs(from: manager)["com.apple.Safari"])
        
        // Mock using NSRunningApplication
        let mockApp = MockRunningApplication(bundleIdentifier: "com.apple.Safari")
        let notificationApp = Notification(
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: mockApp]
        )
        
        NSWorkspace.shared.notificationCenter.post(notificationApp)
        
        XCTAssertNil(getActivePIDs(from: manager)["com.apple.Safari"], "Tapped app should be cleaned up on didTerminateApplicationNotification")
        
        // Now test the fallback bundleIdentifier string
        manager.startAppTapping(bundleID: "com.apple.Finder", pid: 98766)
        XCTAssertNotNil(getActivePIDs(from: manager)["com.apple.Finder"])
        
        let notificationFallback = Notification(
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            userInfo: ["bundleIdentifier": "com.apple.Finder"]
        )
        
        NSWorkspace.shared.notificationCenter.post(notificationFallback)
        
        XCTAssertNil(getActivePIDs(from: manager)["com.apple.Finder"], "Tapped app should be cleaned up using fallback bundleIdentifier key")
    }
    
    // 2. PID liveness check clean up test
    func testPIDLivenessCheckCleansUpDeadPIDs() throws {
        let manager = createTestManager()
        
        // Start tapping for a fake/dead PID (e.g. 99999)
        manager.startAppTapping(bundleID: "com.apple.Safari", pid: 99999)
        XCTAssertNotNil(getActivePIDs(from: manager)["com.apple.Safari"])
        
        // Run the exposed checkPIDsLiveness method
        manager.testExposeCheckPIDsLiveness()
        
        // Verify that Safari tap was removed because PID 99999 is dead
        XCTAssertNil(getActivePIDs(from: manager)["com.apple.Safari"], "Dead PID should be cleaned up by liveness check")
        
        // Start tapping for a live PID (e.g., our own PID)
        let ownPID = getpid()
        manager.startAppTapping(bundleID: "com.apple.Safari", pid: ownPID)
        XCTAssertNotNil(getActivePIDs(from: manager)["com.apple.Safari"])
        
        // Run liveness check
        manager.testExposeCheckPIDsLiveness()
        
        // Verify that Safari tap remains because our own PID is alive
        XCTAssertNotNil(getActivePIDs(from: manager)["com.apple.Safari"], "Live PID should not be cleaned up by liveness check")
    }
}
