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
}
