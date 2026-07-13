import Foundation
import AppKit
import CoreAudio

// Compile with:
// swiftc Sources/Core/AudioProcess.swift adversarial_tests.swift -o adversarial_tests && ./adversarial_tests

@main
struct AdversarialTests {
    static var totalTests = 0
    static var failedTests = 0
    
    static func main() {
        print("==============================")
        print("STARTING ADVERSARIAL TESTS")
        print("==============================")
        fflush(stdout)
        
        runTest("testPaintNetClassic", testPaintNetClassic)
        runTest("testSpotSpotifyContainment", testSpotSpotifyContainment)
        runTest("testGoogleChromeGooglePrefix", testGoogleChromeGooglePrefix)
        runTest("testUnicodeAndSpecialSymbols", testUnicodeAndSpecialSymbols)
        runTest("testExtremelyLongNames", testExtremelyLongNames)
        runTest("testDeterministicFallbackStability", testDeterministicFallbackStability)
        
        print("==============================")
        print("ADVERSARIAL TEST RUN SUMMARY:")
        print("  Total Tests: \(totalTests)")
        print("  Failed/Warned Tests: \(failedTests)")
        print("==============================")
        fflush(stdout)
        
        // Since some of these are exploratory warnings rather than hard failures,
        // we'll report passing if they conform to the specification,
        // but we'll print warnings.
    }
    
    static func runTest(_ name: String, _ testFunc: () -> Void) {
        totalTests += 1
        print("Running \(name)...")
        fflush(stdout)
        testFunc()
        fflush(stdout)
    }
    
    static func check(_ condition: Bool, _ message: String) {
        if condition {
            print("  [PASS] \(message)")
        } else {
            failedTests += 1
            print("  [FAIL] \(message)")
        }
        fflush(stdout)
    }
    
    static func warn(_ condition: Bool, _ message: String) {
        if condition {
            print("  [PASS] \(message)")
        } else {
            print("  [WARN] \(message)")
        }
        fflush(stdout)
    }
    
    private static func proc(_ id: AudioObjectID, _ name: String, bundleID: String = "",
                             regular: Bool = true, output: Bool = false, icon: NSImage? = nil) -> AudioProcess {
        AudioProcess(audioObjectID: id, pid: pid_t(id), bundleID: bundleID, name: name,
                     icon: icon, isRunningOutput: output, isRegularApp: regular)
    }
    
    // 1. Paint.NET.Classic vs process 123
    static func testPaintNetClassic() {
        let pMain = proc(2, "Paint.NET.Classic", bundleID: "com.paint.net.classic")
        let pHelper = proc(1, "process 123", bundleID: "com.paint.net.classic")
        
        let result = AudioProcess.visibleRows(from: [pMain, pHelper], tappedBundleIDs: [])
        check(result.count == 1, "Should deduplicate to 1 row")
        check(result[0].name == "Paint.NET.Classic", "Paint.NET.Classic should win over process 123 (got: \(result[0].name))")
    }
    
    // 2. Spot vs Spotify
    static func testSpotSpotifyContainment() {
        let pSpotify = proc(2, "Spotify", bundleID: "com.spotify.client")
        let pSpot = proc(1, "Spot", bundleID: "com.spotify.client")
        
        let result = AudioProcess.visibleRows(from: [pSpotify, pSpot], tappedBundleIDs: [])
        check(result.count == 1, "Should deduplicate to 1 row")
        // Spotify is the real app, but 'Spot' is shorter and is a prefix/contained.
        check(result[0].name == "Spotify", "Spotify wins over Spot (got: \(result[0].name))")
    }
    
    // 3. Google Chrome vs Google
    static func testGoogleChromeGooglePrefix() {
        let pChrome = proc(2, "Google Chrome", bundleID: "com.google.Chrome")
        let pGoogle = proc(1, "Google", bundleID: "com.google.Chrome")
        
        let result = AudioProcess.visibleRows(from: [pChrome, pGoogle], tappedBundleIDs: [])
        check(result.count == 1, "Should deduplicate to 1 row")
        check(result[0].name == "Google Chrome", "Google Chrome wins over Google (got: \(result[0].name))")
    }
    
    // 4. Unicode and Special Symbols
    static func testUnicodeAndSpecialSymbols() {
        let pMain = proc(2, "✨Sparkles App✨", bundleID: "com.sparkles")
        let pHelper = proc(1, "Sparkles App Helper", bundleID: "com.sparkles")
        
        let result = AudioProcess.visibleRows(from: [pMain, pHelper], tappedBundleIDs: [])
        check(result.count == 1, "Should deduplicate")
        check(result[0].name == "✨Sparkles App✨", "Should choose the main app name with emojis")
    }
    
    // 5. Extremely Long Names
    static func testExtremelyLongNames() {
        let longName = String(repeating: "A", count: 10000)
        let p1 = proc(1, longName, bundleID: "com.long")
        let p2 = proc(2, "Short", bundleID: "com.long")
        
        let start = DispatchTime.now()
        let result = AudioProcess.visibleRows(from: [p1, p2], tappedBundleIDs: [])
        let end = DispatchTime.now()
        let nanoTime = end.uptimeNanoseconds - start.uptimeNanoseconds
        let timeInterval = Double(nanoTime) / 1_000_000_000
        
        check(result.count == 1, "Should deduplicate long name")
        print("  Info: Long name execution time = \(timeInterval) seconds")
        check(timeInterval < 0.1, "Long name processing should be fast")
    }
    
    // 6. Deterministic Fallback Stability
    static func testDeterministicFallbackStability() {
        // Test that if we have multiple processes with identical characteristics,
        // the selection is deterministic and doesn't change on reordering.
        let p1 = proc(1, "SameName", bundleID: "com.same")
        let p2 = proc(2, "SameName", bundleID: "com.same")
        let p3 = proc(3, "SameName", bundleID: "com.same")
        
        let res1 = AudioProcess.visibleRows(from: [p1, p2, p3], tappedBundleIDs: [])
        let res2 = AudioProcess.visibleRows(from: [p3, p2, p1], tappedBundleIDs: [])
        let res3 = AudioProcess.visibleRows(from: [p2, p3, p1], tappedBundleIDs: [])
        
        check(res1[0].audioObjectID == res2[0].audioObjectID && res2[0].audioObjectID == res3[0].audioObjectID,
              "Selection should be deterministic regardless of input order")
    }
}
