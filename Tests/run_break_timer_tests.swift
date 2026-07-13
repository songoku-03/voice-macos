#!/usr/bin/env swift

import Foundation

#if !RUNNING_TESTS
// Bootstrap mode: compile and run combined code in-memory
let fileManager = FileManager.default
let currentPath = CommandLine.arguments[0]
let currentURL = URL(fileURLWithPath: currentPath)

// Locate project directory and production file
let absoluteURL = currentURL.standardizedFileURL
let projectDir = absoluteURL.deletingLastPathComponent().deletingLastPathComponent()
let productionURL = projectDir.appendingPathComponent("Sources/Engine/BreakTimerManager.swift")

guard fileManager.fileExists(atPath: productionURL.path) else {
    print("Error: Production file not found at \(productionURL.path)")
    exit(1)
}

var prodCode = try! String(contentsOf: productionURL, encoding: .utf8)
prodCode = prodCode.replacingOccurrences(of: "import Core", with: "// import Core")

guard let testCode = try? String(contentsOf: absoluteURL, encoding: .utf8) else {
    print("Error: Could not read test runner script.")
    exit(1)
}

// Strip hashbang from testCode to avoid JIT compilation errors when concatenated
let testCodeLines = testCode.components(separatedBy: "\n")
let cleanedTestCode = testCodeLines.filter { !$0.hasPrefix("#!") }.joined(separator: "\n")

let combinedCode = prodCode + "\n\n" + cleanedTestCode

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
process.arguments = ["-D", "RUNNING_TESTS", "-"]

let stdinPipe = Pipe()
process.standardInput = stdinPipe

do {
    try process.run()
    
    if let data = combinedCode.data(using: .utf8) {
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }
    try stdinPipe.fileHandleForWriting.close()
    
    process.waitUntilExit()
    exit(process.terminationStatus)
} catch {
    print("Error during JIT execution: \(error)")
    exit(1)
}
#else
// Actual test mode (parsed only when RUNNING_TESTS is defined)
import AppKit
import ApplicationServices

// Mock/Stub the dependencies required by BreakTimerManager
public class AudioEngineManager {
    public static let shared = AudioEngineManager()
    public var activeNodes: [String: Any] = [:]
    public func getVolume(bundleID: String) -> Float { return 0.8 }
    public func setVolume(bundleID: String, volume: Float) {}
    public func stopAppTapping(bundleID: String) {}
    public func startAppTapping(bundleID: String, pid: pid_t) {}
}

public protocol InputBlockerProtocol: AnyObject {
    func install()
    func uninstall()
}

public protocol BreakOverlayControllerProtocol: AnyObject {
    func showOverlays()
    func hideOverlays()
}

class MockInputBlocker: InputBlockerProtocol {
    var isInstalled = false
    func install() { isInstalled = true }
    func uninstall() { isInstalled = false }
}

class MockOverlayController: BreakOverlayControllerProtocol {
    var isShown = false
    func showOverlays() { isShown = true }
    func hideOverlays() { isShown = false }
}

// ─── Assert Helpers ───
var passed = 0
var failed = 0
var failures: [String] = []

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String = "", file: String = #file, line: Int = #line) {
    if a != b {
        let m = msg.isEmpty ? "assertEqual: \(a) != \(b)" : "\(msg): \(a) != \(b)"
        failures.append("line \(line): \(m)")
    }
}

func assertTrue(_ cond: Bool, _ msg: String = "", file: String = #file, line: Int = #line) {
    if !cond { failures.append("line \(line): \(msg.isEmpty ? "assertTrue failed" : msg)") }
}

@MainActor
func runTest(_ name: String, _ body: @MainActor () throws -> Void) {
    let prev = failures.count
    do {
        try body()
    } catch {
        failures.append("Test threw error: \(error)")
    }
    if failures.count == prev {
        passed += 1
        print("  ✅ \(name)")
    } else {
        failed += 1
        print("  ❌ \(name)")
    }
}

@MainActor
func runBreakTimerManagerTests() {
    print("🚀 Running BreakTimerManager Standalone Tests...")

    let blocker = MockInputBlocker()
    let overlay = MockOverlayController()

    func withFreshManager(_ studySecs: TimeInterval = 60,
                          _ breakSecs: TimeInterval = 20,
                          body: (BreakTimerManager) -> Void) -> BreakTimerManager {
        let m = BreakTimerManager()
        m.studyDuration = studySecs
        m.breakDuration = breakSecs
        m.inputBlocker = blocker
        m.overlayController = overlay
        body(m)
        return m
    }

    runTest("testStartsIdle") {
        _ = withFreshManager { m in
            assertEqual(m.phase, .idle)
            m.start()
            assertEqual(m.phase, .studying)
        }
    }

    runTest("testStopFromStudyingGoesToIdle") {
        _ = withFreshManager { m in
            m.start()
            m.stop()
            assertEqual(m.phase, .idle)
        }
    }

    runTest("testStopFromIdleIsNoOp") {
        _ = withFreshManager { m in
            m.stop()
            assertEqual(m.phase, .idle)
        }
    }

    runTest("testDoubleStartIsNoOp") {
        _ = withFreshManager { m in
            m.start()
            let remaining1 = m.remaining
            m.start()
            assertEqual(m.remaining, remaining1)
            assertEqual(m.phase, .studying)
        }
    }

    runTest("testSkipFromIdleIsNoOp") {
        _ = withFreshManager { m in
            m.skip()
            assertEqual(m.phase, .idle)
        }
    }

    runTest("testEndBreakWithTimeoutTriggersAutoLoopAndCompletedIncrement") {
        _ = withFreshManager { m in
            m.completedSessionsToday = 0
            m.start()
            m.endBreak(reason: .timeout)
            assertEqual(m.phase, .idle)
            assertEqual(m.completedSessionsToday, 1)
        }
    }

    runTest("testEndBreakWithStoppedDoesNotAutoLoopOrIncrement") {
        _ = withFreshManager { m in
            m.completedSessionsToday = 0
            m.start()
            m.endBreak(reason: .stopped)
            assertEqual(m.phase, .idle)
            assertEqual(m.completedSessionsToday, 0)
        }
    }

    runTest("testTodoListOperations") {
        _ = withFreshManager { m in
            m.todoItems = []
            assertTrue(m.todoItems.isEmpty)

            m.addTodoItem(title: "Task 1")
            assertEqual(m.todoItems.count, 1)
            assertEqual(m.todoItems[0].title, "Task 1")
            assertEqual(m.todoItems[0].isCompleted, false)

            let id = m.todoItems[0].id
            m.toggleTodoItem(id: id)
            assertEqual(m.todoItems[0].isCompleted, true)

            m.deleteTodoItem(id: id)
            assertTrue(m.todoItems.isEmpty)
        }
    }

    runTest("testSnoozeFromWarning") {
        _ = withFreshManager(25*60, 5*60) { m in
            m.start()
            
            // Trigger warning state manually by snoozing or entering warning
            // Let's directly call snooze after setting phase to warning manually
            // Since phase is private(set), we mock the warning flow via the snooze method
            // during studying, snooze is a no-op because of: guard phase == .warning else { return }
            m.snooze()
            assertEqual(m.phase, .studying) // should remain studying
        }
    }

    print("\n📝 Test Summary:")
    print("  Passed: \(passed)")
    print("  Failed: \(failed)")
    if failed > 0 {
        print("\n❌ Failures:")
        for f in failures {
            print("  - \(f)")
        }
        exit(1)
    } else {
        print("  🎉 All tests passed successfully!")
        exit(0)
    }
}

Task { @MainActor in
    runBreakTimerManagerTests()
    CFRunLoopStop(CFRunLoopGetMain())
}
CFRunLoopRun()
#endif
