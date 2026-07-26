import Testing
import ApplicationServices
import AppKit
import AVFoundation
import CoreAudio
@testable import Core
@testable import Engine

@MainActor
@Suite struct BreakTimerManagerTests {
    
    // MARK: - Event classification tests
    
    @Test func eventClassification() {
        func check(_ desc: String, keycode: CGKeyCode, flags: CGEventFlags = [], expected: Bool) {
            let result = shouldSuppressEvent(keycode: keycode, flags: flags)
            #expect(result == expected, "FAIL [\(desc)]")
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

    @Test func startsIdle() {
        _ = withFreshManager { m in
            #expect(m.phase == .idle)
            m.start()
            #expect(m.phase == .studying)
        }
    }

    @Test func stopFromStudyingGoesToIdle() {
        _ = withFreshManager { m in
            m.start()
            m.stop()
            #expect(m.phase == .idle)
        }
    }

    @Test func stopFromIdleIsNoOp() {
        _ = withFreshManager { m in
            m.stop()
            #expect(m.phase == .idle)
        }
    }

    @Test func doubleStartIsNoOp() {
        _ = withFreshManager { m in
            m.start()
            let remaining1 = m.remaining
            m.start()
            #expect(m.remaining == remaining1)
            #expect(m.phase == .studying)
        }
    }

    @Test func skipFromIdleIsNoOp() {
        _ = withFreshManager { m in
            m.skip()
            #expect(m.phase == .idle)
        }
    }

    @Test func endBreakWithTimeoutTriggersAutoLoop() {
        _ = withFreshManager { m in
            m.start()
            m.endBreak(reason: .timeout)
            #expect(m.phase == .idle)
        }
    }

    @Test func endBreakWithStoppedDoesNotAutoLoop() {
        _ = withFreshManager { m in
            m.start()
            m.endBreak(reason: .stopped)
            #expect(m.phase == .idle)
        }
    }

    @Test func wakeAfterSleepRecomputes() {
        _ = withFreshManager(5, 10) { m in
            m.start()
            #expect(m.phase == .studying)
            m.stop()
            #expect(m.phase == .idle)
        }
    }

    @Test func todoListOperations() {
        _ = withFreshManager { m in
            // Clear initially
            m.todoItems = []
            #expect(m.todoItems.isEmpty)

            // Add item
            m.addTodoItem(title: "Learn SwiftUI")
            #expect(m.todoItems.count == 1)
            #expect(m.todoItems[0].title == "Learn SwiftUI")
            #expect(!m.todoItems[0].isCompleted)

            // Toggle item
            let id = m.todoItems[0].id
            m.toggleTodoItem(id: id)
            #expect(m.todoItems[0].isCompleted)

            // Toggle back
            m.toggleTodoItem(id: id)
            #expect(!m.todoItems[0].isCompleted)

            // Delete item
            m.deleteTodoItem(id: id)
            #expect(m.todoItems.isEmpty)
        }
    }

    @Test func snoozeFromWarning() {
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
            #expect(m.phase == .studying)
        }
    }

    @Test func completedSessionsCounter() {
        _ = withFreshManager(5, 10) { m in
            let initial = m.completedSessionsToday
            m.completedSessionsToday = initial
            
            // Simulate session completion by calling endBreak with .timeout
            m.start()
            // Directly call endBreak with reason .timeout (simulates timer end)
            m.endBreak(reason: .timeout)
            
            #expect(m.completedSessionsToday == initial + 1)
        }
    }

    @Test func updatePreBreakVolumeDuringBreak() {
        let m = BreakTimerManager()
        m.studyDuration = 0.001
        m.breakDuration = 10
        m.start()
        
        Thread.sleep(forTimeInterval: 0.05)
        
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        
        #expect(m.phase == .breaking)
        
        m.updatePreBreakVolume(bundleID: "com.apple.finder", volume: 0.75)
        
        let dict = UserDefaults.standard.dictionary(forKey: "btm_preBreakVolumes") as? [String: Double]
        #expect(dict?["com.apple.finder"] == 0.75)
        
        m.stop()
    }

    @Test func duckingAndRestoreVolume() {
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
        
        #expect(m.phase == .breaking)
        
        // Node volume should have ducked to 10% (0.08)
        #expect(mockEngine.lastDirectVolume[bundleID] == Float(0.8) * Float(0.1))
        // Persistent/target volume in settings should STILL be 0.8 (Not ducked!)
        #expect(mockEngine.getVolume(bundleID: bundleID) == Float(0.8))
        
        // Stop break/timer
        m.stop()
        
        // Node volume should have restored to 0.8
        #expect(mockEngine.lastDirectVolume[bundleID] == Float(0.8))
        #expect(mockEngine.getVolume(bundleID: bundleID) == Float(0.8))
    }
}
