import Foundation
import AppKit
import CoreAudio

@main
struct StressTestsRun {
    static var totalTests = 0
    static var failedTests = 0

    static func main() {
        print("========================================")
        print("STARTING EXTRA STRESS TESTS")
        print("========================================")

        runTest("testLowercaseMainApp_UnrecognizedCapitalizedHelper", testLowercaseMainApp_UnrecognizedCapitalizedHelper)
        runTest("testHelperNameVariationsNoSpaces", testHelperNameVariationsNoSpaces)
        runTest("testShortBundleIDNormalization", testShortBundleIDNormalization)
        runTest("testWhitespaceTrimming", testWhitespaceTrimming)
        runTest("testCaseInsensitivePrefixes", testCaseInsensitivePrefixes)
        runTest("testTieBreakerHelperRepresentative", testTieBreakerHelperRepresentative)

        print("========================================")
        print("EXTRA STRESS TESTS SUMMARY:")
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

    // 1. Lowercase main app vs capitalized helper that is not in the hardcoded helperSubstrings list
    static func testLowercaseMainApp_UnrecognizedCapitalizedHelper() {
        let mainApp = proc(2, "spotify", bundleID: "com.spotify.client")
        let helperApp = proc(1, "Spotify Networking", bundleID: "com.spotify.client")
        
        let result = AudioProcess.visibleRows(from: [mainApp, helperApp], tappedBundleIDs: [])
        check(result.count == 1, "Should merge to 1 row")
        if result.count == 1 {
            let chosen = result[0].name
            check(chosen == "spotify", "Main app 'spotify' should win, but '\(chosen)' won due to capitalization logic!")
        }
    }

    // 2. Helper name variations without spaces (e.g. WebContent, GPUProcess)
    static func testHelperNameVariationsNoSpaces() {
        let mainApp = proc(2, "spotify", bundleID: "com.spotify.client")
        let helperApp = proc(1, "WebContent", bundleID: "com.spotify.client")
        
        let result = AudioProcess.visibleRows(from: [mainApp, helperApp], tappedBundleIDs: [])
        check(result.count == 1, "Should merge to 1 row")
        if result.count == 1 {
            let chosen = result[0].name
            check(chosen == "spotify", "Main app 'spotify' should win over 'WebContent', but '\(chosen)' won!")
        }
        
        let mainApp2 = proc(2, "spotify", bundleID: "com.spotify.client")
        let helperApp2 = proc(1, "GPUProcess", bundleID: "com.spotify.client")
        let result2 = AudioProcess.visibleRows(from: [mainApp2, helperApp2], tappedBundleIDs: [])
        check(result2.count == 1, "Should merge to 1 row")
        if result2.count == 1 {
            let chosen = result2[0].name
            check(chosen == "spotify", "Main app 'spotify' should win over 'GPUProcess', but '\(chosen)' won!")
        }
    }

    // 3. Short bundle ID normalization edge cases
    static func testShortBundleIDNormalization() {
        check(AudioProcess.normalizeBundleID("com.helper") == "com.helper", "com.helper should not change")
        check(AudioProcess.normalizeBundleID("helper") == "helper", "helper should not change")
        check(AudioProcess.normalizeBundleID("com.example.helper.renderer") == "com.example", "com.example.helper.renderer -> com.example")
        check(AudioProcess.normalizeBundleID("com.example.helper.app") == "com.example.helper.app", "com.example.helper.app -> com.example.helper.app (breaks on app)")
    }

    // 4. Whitespace trimming in names and bundle IDs
    static func testWhitespaceTrimming() {
        let p = AudioProcess(audioObjectID: 1, pid: 1, bundleID: " \n com.spotify.client.helper \t ", name: " \n spotify \t ", icon: nil, isRunningOutput: false, isRegularApp: true)
        check(p.name == "spotify", "Name should be trimmed to 'spotify', got '\(p.name)'")
        check(p.bundleID == "com.spotify.client", "Bundle ID should be trimmed and normalized, got '\(p.bundleID)'")
    }

    // 5. Case-insensitive prefixes (process )
    static func testCaseInsensitivePrefixes() {
        let mainApp = proc(2, "Spotify", bundleID: "com.spotify.client")
        let helperApp1 = proc(1, "PROCESS 123", bundleID: "com.spotify.client")
        let helperApp2 = proc(3, "PrOcEsS 456", bundleID: "com.spotify.client")
        let helperApp3 = proc(4, "Process\t789", bundleID: "com.spotify.client") // tab separator
        
        let result1 = AudioProcess.visibleRows(from: [mainApp, helperApp1], tappedBundleIDs: [])
        check(result1.count == 1, "Should merge to 1 row")
        check(result1.first?.name == "Spotify", "Spotify should win over PROCESS 123")

        let result2 = AudioProcess.visibleRows(from: [mainApp, helperApp2], tappedBundleIDs: [])
        check(result2.count == 1, "Should merge to 1 row")
        check(result2.first?.name == "Spotify", "Spotify should win over PrOcEsS 456")

        let result3 = AudioProcess.visibleRows(from: [mainApp, helperApp3], tappedBundleIDs: [])
        check(result3.count == 1, "Should merge to 1 row")
        check(result3.first?.name == "Spotify", "Spotify should win over Process\\t789")
    }

    // 6. Tie-breaker behavior when helper has lower ID
    static func testTieBreakerHelperRepresentative() {
        // Both capitalized, neither is recognized helper.
        // Spotify (ID 2) vs Spotify Networking (ID 1)
        let mainApp = proc(2, "Spotify", bundleID: "com.spotify.client")
        let helperApp = proc(1, "Spotify Networking", bundleID: "com.spotify.client")
        
        let result = AudioProcess.visibleRows(from: [mainApp, helperApp], tappedBundleIDs: [])
        check(result.count == 1, "Should merge to 1 row")
        if result.count == 1 {
            let chosen = result[0].name
            check(chosen == "Spotify", "Main app 'Spotify' should win over helper 'Spotify Networking' despite higher ID, but '\(chosen)' won!")
        }
    }
}
