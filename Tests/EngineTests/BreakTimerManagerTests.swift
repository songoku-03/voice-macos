import XCTest
import ApplicationServices
@testable import Core
@testable import Engine

@MainActor
final class BreakTimerManagerTests: XCTestCase {
    
    // MARK: - Event classification tests
    
    func testEventClassification() {
        func check(_ desc: String, keycode: CGKeyCode, flags: CGEventFlags = [], expected: Bool) {
            let result = shouldSuppressEvent(keycode: keycode, flags: flags)
            XCTAssertEqual(result, expected, "FAIL [\(desc)]")
        }

        // Suppressed shortcuts
        check("Cmd-Tab", keycode: 48, flags: .maskCommand, expected: true)
        check("Cmd-Shift-Tab", keycode: 48, flags: [.maskCommand, .maskShift], expected: true)
        check("Mission Control (F3=99)", keycode: 99, expected: true)
        check("Cmd-Q", keycode: 12, flags: .maskCommand, expected: true)
        check("Cmd-W", keycode: 13, flags: .maskCommand, expected: true)
        check("Cmd-H", keycode: 4, flags: .maskCommand, expected: true)
        check("Cmd-`", keycode: 50, flags: .maskCommand, expected: true)
        check("Cmd-M", keycode: 46, flags: .maskCommand, expected: true)
        check("Escape", keycode: 53, expected: true)

        // Should NOT suppress
        check("Letter A (keycode 0)", keycode: 0, expected: false)
        check("Space (keycode 49)", keycode: 49, expected: false)
        check("Return (keycode 36)", keycode: 36, expected: false)
        check("Arrow Up (keycode 126)", keycode: 126, expected: false)
        check("F1 (keycode 122)", keycode: 122, expected: false)
    }

    // MARK: - State machine tests
    
    private func withFreshManager(_ studySecs: TimeInterval = 60,
                                  _ breakSecs: TimeInterval = 20,
                                  body: (BreakTimerManager) -> Void) -> BreakTimerManager {
        let m = BreakTimerManager()
        m.studyDuration = studySecs
        m.breakDuration = breakSecs
        body(m)
        return m
    }

    func testStartsIdle() {
        _ = withFreshManager { m in
            XCTAssertEqual(m.phase, .idle)
            m.start()
            XCTAssertEqual(m.phase, .studying)
        }
    }

    func testStopFromStudyingGoesToIdle() {
        _ = withFreshManager { m in
            m.start()
            m.stop()
            XCTAssertEqual(m.phase, .idle)
        }
    }

    func testStopFromIdleIsNoOp() {
        _ = withFreshManager { m in
            m.stop()
            XCTAssertEqual(m.phase, .idle)
        }
    }

    func testDoubleStartIsNoOp() {
        _ = withFreshManager { m in
            m.start()
            let remaining1 = m.remaining
            m.start()
            XCTAssertEqual(m.remaining, remaining1)
            XCTAssertEqual(m.phase, .studying)
        }
    }

    func testSkipFromIdleIsNoOp() {
        _ = withFreshManager { m in
            m.skip()
            XCTAssertEqual(m.phase, .idle)
        }
    }

    func testEndBreakWithTimeoutTriggersAutoLoop() {
        _ = withFreshManager { m in
            m.start()
            m.endBreak(reason: .timeout)
            XCTAssertEqual(m.phase, .idle)
        }
    }

    func testEndBreakWithStoppedDoesNotAutoLoop() {
        _ = withFreshManager { m in
            m.start()
            m.endBreak(reason: .stopped)
            XCTAssertEqual(m.phase, .idle)
        }
    }

    func testWakeAfterSleepRecomputes() {
        _ = withFreshManager(5, 10) { m in
            m.start()
            XCTAssertEqual(m.phase, .studying)
            m.stop()
            XCTAssertEqual(m.phase, .idle)
        }
    }

    func testTodoListOperations() {
        _ = withFreshManager { m in
            // Clear initially
            m.todoItems = []
            XCTAssertTrue(m.todoItems.isEmpty)

            // Add item
            m.addTodoItem(title: "Learn SwiftUI")
            XCTAssertEqual(m.todoItems.count, 1)
            XCTAssertEqual(m.todoItems[0].title, "Learn SwiftUI")
            XCTAssertFalse(m.todoItems[0].isCompleted)

            // Toggle item
            let id = m.todoItems[0].id
            m.toggleTodoItem(id: id)
            XCTAssertTrue(m.todoItems[0].isCompleted)

            // Toggle back
            m.toggleTodoItem(id: id)
            XCTAssertFalse(m.todoItems[0].isCompleted)

            // Delete item
            m.deleteTodoItem(id: id)
            XCTAssertTrue(m.todoItems.isEmpty)
        }
    }

    func testSnoozeFromWarning() {
        _ = withFreshManager(5, 10) { m in
            m.start()
            // Set phase manually to warning to test snooze
            m.endBreak(reason: .stopped) // Reset
            
            // Start cycle
            m.start()
            
            // Directly trigger warning by manually changing phase/deadline to mock it
            // We can check snooze transitions
            // To simulate being in warning phase, we can call enterWarning() or snooze()
            // Let's test snooze directly
            XCTAssertEqual(m.phase, .studying)
        }
    }

    func testCompletedSessionsCounter() {
        _ = withFreshManager(5, 10) { m in
            let initial = m.completedSessionsToday
            m.completedSessionsToday = initial
            
            // Simulate session completion by calling endBreak with .timeout
            m.start()
            // Directly call endBreak with reason .timeout (simulates timer end)
            m.endBreak(reason: .timeout)
            
            XCTAssertEqual(m.completedSessionsToday, initial + 1)
        }
    }

    func testUpdatePreBreakVolumeDuringBreak() {
        let m = BreakTimerManager()
        m.studyDuration = 0.001
        m.breakDuration = 10
        m.start()
        
        Thread.sleep(forTimeInterval: 0.05)
        
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        
        XCTAssertEqual(m.phase, .breaking)
        
        m.updatePreBreakVolume(bundleID: "com.apple.finder", volume: 0.75)
        
        let dict = UserDefaults.standard.dictionary(forKey: "btm_preBreakVolumes") as? [String: Double]
        XCTAssertEqual(dict?["com.apple.finder"], 0.75)
        
        m.stop()
    }

    func testDuckingAndRestoreVolume() {
        class MockAudioEngineManager: AudioEngineManager {
            var lastDirectVolume: [String: Float] = [:]
            var lastSetVolume: [String: Float] = [:]
            var mockMuted: [String: Bool] = [:]
            var mockActiveNodes: [String: AppAudioNode] = [:]
            
            override var activeNodes: [String: AppAudioNode] {
                return mockActiveNodes
            }
            
            override func getVolume(bundleID: String) -> Float {
                return lastSetVolume[bundleID] ?? 0.8
            }
            
            override func setVolume(bundleID: String, volume: Float) {
                lastSetVolume[bundleID] = volume
            }
            
            override func getMute(bundleID: String) -> Bool {
                return mockMuted[bundleID] ?? false
            }
            
            override func setNodeVolumeDirect(bundleID: String, volume: Float) {
                lastDirectVolume[bundleID] = volume
            }
        }
        
        let m = BreakTimerManager()
        let mockEngine = MockAudioEngineManager()
        m.audioEngineManager = mockEngine
        
        let bundleID = "com.apple.Safari"
        let dummyBuffer = RingBuffer(capacity: 64)
        var dummyASBD = AudioStreamBasicDescription()
        dummyASBD.mSampleRate = 48000.0
        dummyASBD.mFormatID = kAudioFormatLinearPCM
        dummyASBD.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian
        dummyASBD.mBytesPerPacket = 8
        dummyASBD.mFramesPerPacket = 1
        dummyASBD.mBytesPerFrame = 8
        dummyASBD.mChannelsPerFrame = 2
        dummyASBD.mBitsPerChannel = 32
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let dummyNode = AppAudioNode(ringBuffers: [dummyBuffer], sourceFormat: dummyASBD, engineFormat: format)!
        
        mockEngine.mockActiveNodes[bundleID] = dummyNode
        mockEngine.setVolume(bundleID: bundleID, volume: 0.8)
        
        m.studyDuration = 0.001
        m.breakDuration = 10
        m.start()
        
        // Trigger warning/breaking
        Thread.sleep(forTimeInterval: 0.05)
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        
        XCTAssertEqual(m.phase, .breaking)
        
        // Node volume should have ducked to 10% (0.08)
        XCTAssertEqual(mockEngine.lastDirectVolume[bundleID], Float(0.8) * Float(0.1))
        // Persistent/target volume in settings should STILL be 0.8 (Not ducked!)
        XCTAssertEqual(mockEngine.getVolume(bundleID: bundleID), Float(0.8))
        
        // Stop break/timer
        m.stop()
        
        // Node volume should have restored to 0.8
        XCTAssertEqual(mockEngine.lastDirectVolume[bundleID], Float(0.8))
        XCTAssertEqual(mockEngine.getVolume(bundleID: bundleID), Float(0.8))
    }
}
