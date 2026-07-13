import Foundation
import AppKit
import CoreAudio

// Compile with:
// swiftc Sources/Core/AudioProcess.swift stress_test_challenger.swift -o stress_test_challenger && ./stress_test_challenger

@main
struct StressTestChallenger {
    static var totalTests = 0
    static var failedTests = 0

    static func main() {
        print("========================================")
        print("RUNNING CHALLENGER STRESS TESTS")
        print("========================================")
        
        runTest("testHelperNameHijacking_SubString", testHelperNameHijacking_SubString)
        runTest("testHelperNameHijacking_TrailingSpace", testHelperNameHijacking_TrailingSpace)
        runTest("testBundleIDNormalization_TrailingSpace", testBundleIDNormalization_TrailingSpace)
        runTest("testBundleIDNormalization_MidComponent", testBundleIDNormalization_MidComponent)
        runTest("testLowercaseMainApp_CapitalizedHelper", testLowercaseMainApp_CapitalizedHelper)
        runTest("testEmptyAndWhitespaceHandling", testEmptyAndWhitespaceHandling)
        runTest("testSpecialCharactersFirstChar", testSpecialCharactersFirstChar)
        runTest("testTransitiveBridgingCheck", testTransitiveBridgingCheck)

        print("========================================")
        print("STRESS TEST SUMMARY:")
        print("  Total: \(totalTests)")
        print("  Failed: \(failedTests)")
        print("========================================")
        
        if failedTests > 0 {
            exit(1)
        }
    }

    static func runTest(_ name: String, _ testFunc: () -> Void) {
        totalTests += 1
        print("Running \(name)...")
        testFunc()
    }

    static func check(_ condition: Bool, _ message: String) {
        if condition {
            print("  [PASS] \(message)")
        } else {
            failedTests += 1
            print("  [FAIL] \(message)")
        }
    }

    private static func proc(_ id: AudioObjectID, _ name: String, bundleID: String = "",
                             regular: Bool = true, output: Bool = false, icon: NSImage? = nil) -> AudioProcess {
        AudioProcess(audioObjectID: id, pid: pid_t(id), bundleID: bundleID, name: name,
                     icon: icon, isRunningOutput: output, isRegularApp: regular)
    }

    // 1. Helper name substring hijacking (e.g. "Helper Process" or "Google Chrome Helper")
    static func testHelperNameHijacking_SubString() {
        // Main app: Spotify (ID 2), Helper: Spotify Helper (ID 1)
        let mainApp = proc(2, "Spotify", bundleID: "com.spotify.client")
        let helperApp = proc(1, "Spotify Helper", bundleID: "com.spotify.client")
        
        let result = AudioProcess.visibleRows(from: [mainApp, helperApp], tappedBundleIDs: [])
        check(result.count == 1, "Should merge to 1 row")
        
        // Since "Spotify Helper" is considered localized (starts with S, not in genericHelpers),
        // and its ID is smaller, it wins!
        let chosenName = result[0].name
        check(chosenName == "Spotify", "Main app name 'Spotify' should win, but got: '\(chosenName)'")
    }

    // 2. Helper name trailing space hijacking (e.g. "Helper ")
    static func testHelperNameHijacking_TrailingSpace() {
        let mainApp = proc(2, "Spotify", bundleID: "com.spotify.client")
        let helperApp = proc(1, "Helper ", bundleID: "com.spotify.client") // Trailing space
        
        let result = AudioProcess.visibleRows(from: [mainApp, helperApp], tappedBundleIDs: [])
        check(result.count == 1, "Should merge to 1 row")
        
        let chosenName = result[0].name
        check(chosenName == "Spotify", "Main app name 'Spotify' should win over 'Helper ' (trailing space), but got: '\(chosenName)'")
    }

    // 3. Bundle ID normalization with trailing space
    static func testBundleIDNormalization_TrailingSpace() {
        // If a bundleID has a trailing space like "com.spotify.client.helper "
        let normalized = AudioProcess.normalizeBundleID("com.spotify.client.helper ")
        check(normalized == "com.spotify.client", "Normalized bundleID of 'com.spotify.client.helper ' should be 'com.spotify.client', but got: '\(normalized)'")
    }

    // 4. Bundle ID normalization with mid-components / other helpers
    static func testBundleIDNormalization_MidComponent() {
        // VS Code helper: com.microsoft.VSCode.helper.EH
        let normalized = AudioProcess.normalizeBundleID("com.microsoft.VSCode.helper.EH")
        // Currently, it breaks early because EH is not helper/renderer.
        // But in reality, it's still a helper process of VS Code.
        print("  Info: 'com.microsoft.VSCode.helper.EH' normalized to '\(normalized)'")
    }

    // 5. Lowercase main app name vs capitalized helper name
    static func testLowercaseMainApp_CapitalizedHelper() {
        // Main app has lowercase name "spotify" (ID 2), helper has capitalized name "Helper Process" (ID 1)
        let mainApp = proc(2, "spotify", bundleID: "com.spotify.client")
        let helperApp = proc(1, "Helper Process", bundleID: "com.spotify.client")
        
        let result = AudioProcess.visibleRows(from: [mainApp, helperApp], tappedBundleIDs: [])
        check(result.count == 1, "Should merge to 1 row")
        
        let chosenName = result[0].name
        check(chosenName == "spotify", "Main app name 'spotify' should win, but got: '\(chosenName)'")
    }

    // 6. Empty and Whitespace Handling
    static func testEmptyAndWhitespaceHandling() {
        let p1 = proc(1, " ", bundleID: "com.foo") // space name
        let p2 = proc(2, "App", bundleID: " ") // space bundleID
        let result = AudioProcess.visibleRows(from: [p1, p2], tappedBundleIDs: [])
        
        print("  Info: space name & bundleID visibleRows count: \(result.count)")
        for p in result {
            print("    ID=\(p.audioObjectID), name='\(p.name)', bundleID='\(p.bundleID)'")
        }
    }

    // 7. Special characters as first character of name
    static func testSpecialCharactersFirstChar() {
        let mainApp = proc(2, "@Spotify", bundleID: "com.spotify.client")
        let helperApp = proc(1, "Helper", bundleID: "com.spotify.client")
        
        let result = AudioProcess.visibleRows(from: [mainApp, helperApp], tappedBundleIDs: [])
        check(result.count == 1, "Should merge to 1 row")
        
        let chosenName = result[0].name
        check(chosenName == "@Spotify", "Main app name '@Spotify' should win, but got: '\(chosenName)'")
    }

    // 8. Transitive bridging check
    static func testTransitiveBridgingCheck() {
        // A: name="Helper", bundleID="com.foo"
        // B: name="Helper", bundleID=""
        // C: name="App", bundleID=""
        // Grouping:
        // A and B both have name "Helper" -> sameName = true -> union.
        // B and C both have empty bundleIDs. Do they union?
        // No, sameBundle requires !isEmpty.
        // But do B and C have sameName? No ("Helper" vs "App").
        // So B and C do not union directly.
        // Therefore, we have two groups: {A, B} and {C}.
        // Let's verify.
        let pA = proc(1, "Helper", bundleID: "com.foo")
        let pB = proc(2, "Helper", bundleID: "")
        let pC = proc(3, "App", bundleID: "")
        
        let result = AudioProcess.visibleRows(from: [pA, pB, pC], tappedBundleIDs: [])
        check(result.count == 2, "Expected 2 groups, got: \(result.count)")
    }
}
