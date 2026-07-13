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
let productionURL = projectDir.appendingPathComponent("Sources/Core/AudioProcess.swift")

guard fileManager.fileExists(atPath: productionURL.path) else {
    print("Error: Production file not found at \(productionURL.path)")
    exit(1)
}

guard let prodCode = try? String(contentsOf: productionURL, encoding: .utf8) else {
    print("Error: Could not read production file.")
    exit(1)
}

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
import CoreAudio

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

func assertNotNil(_ a: Any?, _ msg: String = "", file: String = #file, line: Int = #line) {
    if a == nil { failures.append("line \(line): \(msg.isEmpty ? "assertNotNil failed" : msg)") }
}

func runTest(_ name: String, _ body: () throws -> Void) {
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

// ─── Helper to build AudioProcess ───
func proc(_ id: AudioObjectID, _ name: String, bundleID: String = "",
          regular: Bool = true, output: Bool = false) -> AudioProcess {
    AudioProcess(audioObjectID: id, pid: pid_t(id), bundleID: bundleID, name: name,
                 icon: nil, isRunningOutput: output, isRegularApp: regular)
}

print("🚀 Running AudioProcess Tests...")

runTest("testSilentRegularShows") {
    let rows = AudioProcess.visibleRows(
        from: [proc(1, "Spotify", bundleID: "com.spotify.client", regular: true, output: false)],
        tappedBundleIDs: []
    )
    assertEqual(rows.map(\.name), ["Spotify"])
}

runTest("testDaemonsExcluded") {
    let rows = AudioProcess.visibleRows(
        from: [
            proc(1, "audiomxd", bundleID: "com.apple.audiomxd", regular: false, output: false),
            proc(2, "Spotify", bundleID: "com.spotify.client", regular: true)
        ],
        tappedBundleIDs: []
    )
    assertEqual(rows.map(\.name), ["Spotify"])
}

runTest("testDedupesMultiProcess") {
    let rows = AudioProcess.visibleRows(
        from: [
            proc(1, "Google Chrome", bundleID: "com.google.Chrome", regular: true),
            proc(2, "Google Chrome", bundleID: "com.google.Chrome.helper", regular: true),
            proc(3, "Google Chrome", bundleID: "com.google.Chrome.helper", regular: true)
        ],
        tappedBundleIDs: []
    )
    assertEqual(rows.count, 1)
    assertEqual(rows[0].name, "Google Chrome")
}

runTest("testPrefersOutputtingRepresentative") {
    let rows = AudioProcess.visibleRows(
        from: [
            proc(1, "Google Chrome", bundleID: "com.google.Chrome", regular: true, output: false),
            proc(2, "Google Chrome", bundleID: "com.google.Chrome.helper", regular: true, output: true)
        ],
        tappedBundleIDs: []
    )
    assertEqual(rows.count, 1)
    assertEqual(rows[0].bundleID, "com.google.Chrome")
    assertTrue(rows[0].isRunningOutput)
}

runTest("testNormalizeBundleID") {
    assertEqual(AudioProcess.normalizeBundleID("com.google.Chrome"), "com.google.Chrome")
    assertEqual(AudioProcess.normalizeBundleID("com.google.Chrome.helper"), "com.google.Chrome")
    assertEqual(AudioProcess.normalizeBundleID("com.google.Chrome.helper.renderer"), "com.google.Chrome")
    assertEqual(AudioProcess.normalizeBundleID("org.chromium.Chromium.helper.renderer"), "org.chromium.Chromium")
    assertEqual(AudioProcess.normalizeBundleID("com.hnc.Discord.Helper"), "com.hnc.Discord")
    assertEqual(AudioProcess.normalizeBundleID("com.spotify.client.helper"), "com.spotify.client")
    assertEqual(AudioProcess.normalizeBundleID(""), "")
}

runTest("testTappedShowsRegardless") {
    let rows = AudioProcess.visibleRows(
        from: [proc(1, "Weird", bundleID: "com.weird.bg", regular: false, output: false)],
        tappedBundleIDs: ["com.weird.bg"]
    )
    assertEqual(rows.map(\.name), ["Weird"])
}

runTest("testSortedByName") {
    let rows = AudioProcess.visibleRows(
        from: [
            proc(1, "Spotify", bundleID: "com.spotify.client"),
            proc(2, "Discord", bundleID: "com.hnc.Discord"),
            proc(3, "google chrome", bundleID: "com.google.Chrome")
        ],
        tappedBundleIDs: []
    )
    assertEqual(rows.map(\.name), ["Discord", "google chrome", "Spotify"])
}

runTest("testBundleIDGroupingWithDifferentNameCasings") {
    // Grouping by bundle ID with different name casings
    let rowsByBundleID = AudioProcess.visibleRows(
        from: [
            proc(1, "Finder", bundleID: "com.apple.finder", regular: true),
            proc(2, "finder", bundleID: "com.apple.Finder", regular: true)
        ],
        tappedBundleIDs: []
    )
    assertEqual(rowsByBundleID.count, 1)
    // Heuristic 4 (localized name "Finder") should make "Finder" win over "finder"
    assertEqual(rowsByBundleID[0].name, "Finder")

    // Grouping by name when bundle ID is empty
    let rowsByName = AudioProcess.visibleRows(
        from: [
            proc(3, "Finder", bundleID: "", regular: true),
            proc(4, "finder", bundleID: "", regular: true)
        ],
        tappedBundleIDs: []
    )
    assertEqual(rowsByName.count, 1)
    assertEqual(rowsByName[0].name, "Finder")
}

runTest("testRepresentativeHeuristics") {
    // Heuristic 1: Prioritize processes outputting audio
    let rows1 = AudioProcess.visibleRows(
        from: [
            proc(1, "TestApp", bundleID: "com.test", regular: true, output: false),
            proc(2, "TestApp", bundleID: "com.test", regular: true, output: true)
        ],
        tappedBundleIDs: []
    )
    assertEqual(rows1.count, 1)
    assertTrue(rows1[0].isRunningOutput)
    assertEqual(rows1[0].audioObjectID, 2)

    // Heuristic 2: Prioritize regular applications
    let rows2 = AudioProcess.visibleRows(
        from: [
            proc(1, "TestApp", bundleID: "com.test", regular: false, output: false),
            proc(2, "TestApp", bundleID: "com.test", regular: true, output: false)
        ],
        tappedBundleIDs: []
    )
    assertEqual(rows2.count, 1)
    assertTrue(rows2[0].isRegularApp)
    assertEqual(rows2[0].audioObjectID, 2)

    // Heuristic 3: Prioritize processes with icons
    let img = NSImage()
    let rows3 = AudioProcess.visibleRows(
        from: [
            AudioProcess(audioObjectID: 1, pid: 1, bundleID: "com.test", name: "TestApp", icon: nil, isRunningOutput: false, isRegularApp: true),
            AudioProcess(audioObjectID: 2, pid: 2, bundleID: "com.test", name: "TestApp", icon: img, isRunningOutput: false, isRegularApp: true)
        ],
        tappedBundleIDs: []
    )
    assertEqual(rows3.count, 1)
    assertNotNil(rows3[0].icon)
    assertEqual(rows3[0].audioObjectID, 2)

    // Heuristic 4: Prioritize localized names
    let rows4 = AudioProcess.visibleRows(
        from: [
            proc(1, "process test", bundleID: "com.test", regular: true, output: false),
            proc(2, "TestApp", bundleID: "com.test", regular: true, output: false)
        ],
        tappedBundleIDs: []
    )
    assertEqual(rows4.count, 1)
    assertEqual(rows4[0].name, "TestApp")

    // Heuristic 5 (fallback A): Prioritize lower audioObjectID
    let rows5 = AudioProcess.visibleRows(
        from: [
            proc(2, "TestApp", bundleID: "com.test", regular: true, output: false),
            proc(1, "TestApp", bundleID: "com.test", regular: true, output: false)
        ],
        tappedBundleIDs: []
    )
    assertEqual(rows5.count, 1)
    assertEqual(rows5[0].audioObjectID, 1)

    // Heuristic 5 (fallback B): Prioritize lower PID
    let rows6 = AudioProcess.visibleRows(
        from: [
            AudioProcess(audioObjectID: 1, pid: 2, bundleID: "com.test", name: "TestApp", icon: nil, isRunningOutput: false, isRegularApp: true),
            AudioProcess(audioObjectID: 1, pid: 1, bundleID: "com.test", name: "TestApp", icon: nil, isRunningOutput: false, isRegularApp: true)
        ],
        tappedBundleIDs: []
    )
    assertEqual(rows6.count, 1)
    assertEqual(rows6[0].pid, 1)
}

runTest("testDeduplicationEmptyBundleIDSameName") {
    let rows = AudioProcess.visibleRows(
        from: [
            proc(1, "finder", bundleID: "", regular: true),
            proc(2, "Finder", bundleID: "com.apple.finder", regular: true)
        ],
        tappedBundleIDs: []
    )
    assertEqual(rows.count, 1)
    assertEqual(rows[0].name, "Finder")
    assertEqual(rows[0].bundleID, "com.apple.finder")
}

runTest("testNoTransitiveGroupingDifferentBundleIDs") {
    let rows = AudioProcess.visibleRows(
        from: [
            proc(1, "Foo", bundleID: "com.apple.foo"),
            proc(2, "Foo", bundleID: ""),
            proc(3, "Foo", bundleID: "com.apple.bar")
        ],
        tappedBundleIDs: []
    )
    assertEqual(rows.count, 2)
}

runTest("testNormalizeBundleIDMidComponentHelper") {
    assertEqual(AudioProcess.normalizeBundleID("com.example.helper.app"), "com.example.helper.app")
    assertEqual(AudioProcess.normalizeBundleID("com.example.app.helper"), "com.example.app")
}

runTest("testNoEmptyNameCollision") {
    let rows = AudioProcess.visibleRows(
        from: [
            proc(1, "", bundleID: "com.apple.foo"),
            proc(2, "", bundleID: "com.apple.bar")
        ],
        tappedBundleIDs: []
    )
    assertEqual(rows.count, 2)
}

runTest("testCJKAndNumericLocalizationPrioritized") {
    let rows = AudioProcess.visibleRows(
        from: [
            proc(1, "com.example.music", bundleID: "com.example"),
            proc(2, "音乐", bundleID: "com.example")
        ],
        tappedBundleIDs: []
    )
    assertEqual(rows.count, 1)
    assertEqual(rows[0].name, "音乐")

    let rows2 = AudioProcess.visibleRows(
        from: [
            proc(3, "com.agilebits.onepassword", bundleID: "com.1password"),
            proc(4, "1Password", bundleID: "com.1password")
        ],
        tappedBundleIDs: []
    )
    assertEqual(rows2.count, 1)
    assertEqual(rows2[0].name, "1Password")
}

runTest("testGenericHelperNameHijacking") {
    // WeChat ("微信", ID=2) vs capitalized "Helper" (ID=1)
    let pWeChat = proc(2, "微信", bundleID: "com.tencent.xin")
    let pHelper = proc(1, "Helper", bundleID: "com.tencent.xin")
    let result1 = AudioProcess.visibleRows(from: [pWeChat, pHelper], tappedBundleIDs: [])
    assertEqual(result1.count, 1)
    assertEqual(result1[0].name, "微信")

    // Slack ("Slack", ID=2) vs capitalized "Helper" (ID=1)
    let pSlack = proc(2, "Slack", bundleID: "com.tinyspeck.slackmacgap")
    let pHelper2 = proc(1, "Helper", bundleID: "com.tinyspeck.slackmacgap")
    let result2 = AudioProcess.visibleRows(from: [pSlack, pHelper2], tappedBundleIDs: [])
    assertEqual(result2.count, 1)
    assertEqual(result2[0].name, "Slack")
}

runTest("testIteration4EdgeCases") {
    // 1. Lowercase Main App Name Hijacking (lowercase app name vs capitalized helper name)
    let rowsLowercaseApp = AudioProcess.visibleRows(
        from: [
            proc(2, "spotify", bundleID: "com.spotify.client", regular: true),
            proc(1, "Spotify Helper", bundleID: "com.spotify.client", regular: true)
        ],
        tappedBundleIDs: []
    )
    assertEqual(rowsLowercaseApp.count, 1)
    assertEqual(rowsLowercaseApp[0].name, "spotify")
    
    // WeChat vs capitalized WeChat Helper with lower ID
    let resultWeChat = AudioProcess.visibleRows(
        from: [
            proc(2, "wechat", bundleID: "com.tencent.xin", regular: true),
            proc(1, "WeChat Helper", bundleID: "com.tencent.xin", regular: true)
        ],
        tappedBundleIDs: []
    )
    assertEqual(resultWeChat.count, 1)
    assertEqual(resultWeChat[0].name, "wechat")

    // 2. Substring Helper Name Check
    let rowsHelper = AudioProcess.visibleRows(
        from: [
            proc(2, "Google Chrome", bundleID: "com.google.Chrome", regular: true),
            proc(1, "Chrome Helper", bundleID: "com.google.Chrome", regular: true)
        ],
        tappedBundleIDs: []
    )
    assertEqual(rowsHelper.count, 1)
    assertEqual(rowsHelper[0].name, "Google Chrome")

    // 3. Short Bundle ID collapse (prevent TLD collapse)
    assertEqual(AudioProcess.normalizeBundleID("com.helper"), "com.helper")
    assertEqual(AudioProcess.normalizeBundleID("com.renderer"), "com.renderer")
    assertEqual(AudioProcess.normalizeBundleID("com.google.Chrome.helper"), "com.google.Chrome")
    assertEqual(AudioProcess.normalizeBundleID("helper"), "helper")
    
    // 4. Whitespace/newline trimming
    let procWithWhitespace = AudioProcess(
        audioObjectID: 1,
        pid: 1,
        bundleID: "  com.spotify.client.helper \n",
        name: " \nSpotify\n ",
        icon: nil,
        isRunningOutput: false,
        isRegularApp: true
    )
    assertEqual(procWithWhitespace.name, "Spotify")
    assertEqual(procWithWhitespace.bundleID, "com.spotify.client")
    
    // 5. Case-sensitive prefix check for "process " case-insensitively
    let rowsProcessPrefix = AudioProcess.visibleRows(
        from: [
            proc(2, "Spotify", bundleID: "com.spotify.client", regular: true),
            proc(1, "PROCESS 123", bundleID: "com.spotify.client", regular: true)
        ],
        tappedBundleIDs: []
    )
    assertEqual(rowsProcessPrefix.count, 1)
    assertEqual(rowsProcessPrefix[0].name, "Spotify")
    
    // 6. Whitespace-only name hijacking
    let rowsWhitespaceOnly = AudioProcess.visibleRows(
        from: [
            proc(2, "Spotify", bundleID: "com.spotify.client", regular: true),
            proc(1, "   \n   ", bundleID: "com.spotify.client", regular: true)
        ],
        tappedBundleIDs: []
    )
    assertEqual(rowsWhitespaceOnly.count, 1)
    assertEqual(rowsWhitespaceOnly[0].name, "Spotify")
}

runTest("testDeduplicationEdgeCasesIteration5") {
    // 1. Lowercase-first App Name Hijacking (spotify vs Spotify Networking)
    let rows1 = AudioProcess.visibleRows(
        from: [
            proc(2, "spotify", bundleID: "com.spotify.client"),
            proc(1, "Spotify Networking", bundleID: "com.spotify.client")
        ],
        tappedBundleIDs: []
    )
    assertEqual(rows1.count, 1)
    assertEqual(rows1[0].name, "spotify")
    
    // 2. No-Space Helper Blacklist Bypass (spotify vs WebContent/GPUProcess/ServiceWorker)
    let rows2 = AudioProcess.visibleRows(
        from: [
            proc(2, "spotify", bundleID: "com.spotify.client"),
            proc(1, "WebContent", bundleID: "com.spotify.client"),
            proc(3, "GPUProcess", bundleID: "com.spotify.client"),
            proc(4, "ServiceWorker", bundleID: "com.spotify.client")
        ],
        tappedBundleIDs: []
    )
    assertEqual(rows2.count, 1)
    assertEqual(rows2[0].name, "spotify")
    
    // 3. Unrecognized Capitalized Helper Tie-breaker Hijacking (Spotify vs Spotify Networking)
    let rows3 = AudioProcess.visibleRows(
        from: [
            proc(2, "Spotify", bundleID: "com.spotify.client"),
            proc(1, "Spotify Networking", bundleID: "com.spotify.client")
        ],
        tappedBundleIDs: []
    )
    assertEqual(rows3.count, 1)
    assertEqual(rows3[0].name, "Spotify")
    
    // 4. App Name Containing Dot Hijacking (Paint.NET vs process 123)
    let rows4 = AudioProcess.visibleRows(
        from: [
            proc(2, "Paint.NET", bundleID: "com.paint.net"),
            proc(1, "process 123", bundleID: "com.paint.net")
        ],
        tappedBundleIDs: []
    )
    assertEqual(rows4.count, 1)
    assertEqual(rows4[0].name, "Paint.NET")
    
    // 5. Spotify vs Spot (Unrelated Shorter Prefix Name Hijacking)
    let rows5 = AudioProcess.visibleRows(
        from: [
            proc(2, "Spotify", bundleID: "com.spotify.client"),
            proc(1, "Spot", bundleID: "com.spotify.client")
        ],
        tappedBundleIDs: []
    )
    assertEqual(rows5.count, 1)
    assertEqual(rows5[0].name, "Spotify")

    // 6. Renderer's Toolkit vs renderer (Over-aggressive Helper Keyword Penalty)
    let rows6 = AudioProcess.visibleRows(
        from: [
            proc(2, "Renderer's Toolkit", bundleID: "com.toolkit.renderer"),
            proc(1, "renderer", bundleID: "com.toolkit.renderer")
        ],
        tappedBundleIDs: []
    )
    assertEqual(rows6.count, 1)
    assertEqual(rows6[0].name, "Renderer's Toolkit")

    // 7. Google Chrome vs chrome (No-Prefix Matches)
    let rows7 = AudioProcess.visibleRows(
        from: [
            proc(2, "Google Chrome", bundleID: "com.google.chrome"),
            proc(1, "chrome", bundleID: "com.google.chrome")
        ],
        tappedBundleIDs: []
    )
    assertEqual(rows7.count, 1)
    assertEqual(rows7[0].name, "Google Chrome")

    // 8. Mixed-case bundle ID matching
    let rows8 = AudioProcess.visibleRows(
        from: [
            proc(2, "Spotify", bundleID: "com.Spotify.client"),
            proc(1, "Spot", bundleID: "com.spotify.Client")
        ],
        tappedBundleIDs: []
    )
    assertEqual(rows8.count, 1)
    assertEqual(rows8[0].name, "Spotify")
}

// ─── Print Summary ───
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
#endif
