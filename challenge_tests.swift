import Foundation
import AppKit
import CoreAudio

// Compile this along with Sources/Core/AudioProcess.swift:
// swiftc Sources/Core/AudioProcess.swift challenge_tests.swift -o challenge_tests && ./challenge_tests

@main
struct ChallengeTests {
    static var totalTests = 0
    static var failedTests = 0
    
    static func main() {
        print("==============================")
        print("STARTING CHALLENGE TEST SUITE")
        print("==============================")
        fflush(stdout)
        
        runTest("testTransitiveGrouping", testTransitiveGrouping)
        runTest("testOverlappingGroups", testOverlappingGroups)
        runTest("testSpotifyDiscordSeparation", testSpotifyDiscordSeparation)
        runTest("testCJKPrioritization", testCJKPrioritization)
        runTest("testLatinHelperConflict", testLatinHelperConflict)
        runTest("testEmptyAndWeirdInputs", testEmptyAndWeirdInputs)
        runTest("testPerformanceAndBottlenecks", testPerformanceAndBottlenecks)
        
        print("==============================")
        print("TEST RUN SUMMARY:")
        print("  Total Tests: \(totalTests)")
        print("  Failed Tests: \(failedTests)")
        print("==============================")
        fflush(stdout)
        
        if failedTests > 0 {
            exit(1)
        }
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
    
    private static func proc(_ id: AudioObjectID, _ name: String, bundleID: String = "",
                             regular: Bool = true, output: Bool = false, icon: NSImage? = nil) -> AudioProcess {
        AudioProcess(audioObjectID: id, pid: pid_t(id), bundleID: bundleID, name: name,
                     icon: icon, isRunningOutput: output, isRegularApp: regular)
    }
    
    // 1. Transitive Grouping Test
    static func testTransitiveGrouping() {
        let pA = proc(1, "Helper", bundleID: "com.foo")
        let pB = proc(2, "Helper", bundleID: "com.bar")
        let pC = proc(3, "App", bundleID: "com.bar")
        
        let result = AudioProcess.visibleRows(from: [pA, pB, pC], tappedBundleIDs: [])
        check(result.count == 2, "Transitive grouping should not bridge different bundle IDs com.foo and com.bar (result count: \(result.count))")
        
        let hasFoo = result.contains { $0.bundleID == "com.foo" }
        let hasBar = result.contains { $0.bundleID == "com.bar" }
        check(hasFoo && hasBar, "Should contain representatives for both com.foo and com.bar")
    }
    
    // 2. Overlapping Groups Test
    static func testOverlappingGroups() {
        let teams = proc(1, "Microsoft Teams", bundleID: "com.microsoft.teams")
        let teamsHelper = proc(2, "helper", bundleID: "com.microsoft.teams.helper")
        let chromeHelper = proc(3, "helper", bundleID: "com.google.chrome.helper")
        let chrome = proc(4, "Google Chrome", bundleID: "com.google.chrome")
        
        let result = AudioProcess.visibleRows(from: [teams, teamsHelper, chromeHelper, chrome], tappedBundleIDs: [])
        check(result.count == 2, "Teams and Chrome should remain separate even with overlapping 'helper' names (result count: \(result.count))")
        
        let bundles = Set(result.map(\.bundleID))
        check(bundles.contains("com.microsoft.teams"), "Should contain Microsoft Teams")
        check(bundles.contains("com.google.chrome"), "Should contain Google Chrome")
    }
    
    // 3. Spotify and Discord Separation Test
    static func testSpotifyDiscordSeparation() {
        let spotify = proc(1, "Spotify", bundleID: "com.spotify.client")
        let spotifyHelper = proc(2, "helper", bundleID: "com.spotify.client.helper")
        let discordHelper = proc(3, "helper", bundleID: "com.hnc.Discord.Helper")
        let discord = proc(4, "Discord", bundleID: "com.hnc.Discord")
        
        let result = AudioProcess.visibleRows(from: [spotify, spotifyHelper, discordHelper, discord], tappedBundleIDs: [])
        check(result.count == 2, "Spotify and Discord must remain separate (result count: \(result.count))")
        
        let bundles = Set(result.map(\.bundleID))
        check(bundles.contains("com.spotify.client"), "Should contain Spotify")
        check(bundles.contains("com.hnc.Discord"), "Should contain Discord")
    }
    
    // 4. CJK Prioritization Test
    static func testCJKPrioritization() {
        // WeChat (微信, ID 2) vs Helper (ID 1)
        let pWeChat = proc(2, "微信", bundleID: "com.tencent.xin")
        let pHelper = proc(1, "Helper", bundleID: "com.tencent.xin")
        
        let result1 = AudioProcess.visibleRows(from: [pWeChat, pHelper], tappedBundleIDs: [])
        check(result1[0].name == "微信", "WeChat ('微信') should win over 'Helper' despite higher audioObjectID (ID 2 vs 1) -> Selected: '\(result1[0].name)'")
        
        // Case 2: CJK name vs lowercase generic name (e.g. "helper")
        let pMusic = proc(2, "音乐", bundleID: "com.example.music")
        let pHelperLower = proc(1, "helper", bundleID: "com.example.music")
        let result2 = AudioProcess.visibleRows(from: [pMusic, pHelperLower], tappedBundleIDs: [])
        check(result2[0].name == "音乐", "CJK name must win over lowercase non-localized name 'helper' -> Selected: '\(result2[0].name)'")
    }
    
    // 5. Latin Helper Conflict Test
    static func testLatinHelperConflict() {
        // Spotify (ID 2) vs Helper (ID 1)
        let pSpotify = proc(2, "Spotify", bundleID: "com.spotify.client")
        let pHelper = proc(1, "Helper", bundleID: "com.spotify.client")
        
        let result = AudioProcess.visibleRows(from: [pSpotify, pHelper], tappedBundleIDs: [])
        check(result[0].name == "Spotify", "Spotify should win over 'Helper' despite higher audioObjectID (ID 2 vs 1) -> Selected: '\(result[0].name)'")
    }
    
    // 6. Empty and Weird Inputs Test
    static func testEmptyAndWeirdInputs() {
        let p1 = proc(1, "", bundleID: "")
        let p2 = proc(2, "", bundleID: "")
        let p3 = proc(3, "App", bundleID: "")
        
        let result = AudioProcess.visibleRows(from: [p1, p2, p3], tappedBundleIDs: [])
        check(result.count == 3, "Expected 3 representatives because empty names/bundleIDs do not merge (result count: \(result.count))")
    }
    
    // 7. Performance Stress Test
    static func testPerformanceAndBottlenecks() {
        func generateUniqueProcesses(count: Int) -> [AudioProcess] {
            var arr: [AudioProcess] = []
            for i in 1...count {
                arr.append(proc(AudioObjectID(i), "App-\(i)", bundleID: "com.app.\(i)"))
            }
            return arr
        }
        
        let sizes = [10, 100, 500, 1000]
        for size in sizes {
            let list = generateUniqueProcesses(count: size)
            
            let start = DispatchTime.now()
            let result = AudioProcess.visibleRows(from: list, tappedBundleIDs: [])
            let end = DispatchTime.now()
            
            let nanoTime = end.uptimeNanoseconds - start.uptimeNanoseconds
            let timeInterval = Double(nanoTime) / 1_000_000_000
            print("  Size N=\(size): execution time = \(String(format: "%.6f", timeInterval)) seconds")
            fflush(stdout)
            
            if size == 1000 {
                check(timeInterval < 0.5, "Performance for N=1000 should be fast (took \(timeInterval)s)")
            }
        }
    }
}
