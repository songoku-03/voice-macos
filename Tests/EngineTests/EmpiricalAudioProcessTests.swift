import Foundation
import AppKit
import CoreAudio

// Re-declare or import Core if we're compiling standalone.
// Since we are compiling both AudioProcess.swift and this file together,
// they will be in the same module, so we don't need "@testable import Core"
// if we compile them together.

@main
struct EmpiricalAudioProcessTests {
    static func main() {
        print("=== Starting Empirical Tests for AudioProcess ===")
        
        testTransitiveGroupingConflict()
        testOverlappingGroupsWithHelpers()
        testHeuristicTotalOrder()
        testEdgeCases()
        testNonLatinLocalizedNameBug()
        testPerformanceStress()
        
        print("=== All Empirical Tests Completed Successfully ===")
    }
    
    // Test for Non-Latin/Cased Script representative heuristic bug
    static func testNonLatinLocalizedNameBug() {
        print("Running: testNonLatinLocalizedNameBug...")
        // A Chinese name "微信" (WeChat) has no uppercase characters, so isLocalizedName returns false.
        // A helper process "Helper" starts with an uppercase 'H', so isLocalizedName returns true.
        // If they are in the same group, "Helper" will be selected over "微信"!
        let pWeChat = proc(1, "微信", bundleID: "com.tencent.xin")
        let pHelper = proc(2, "Helper", bundleID: "com.tencent.xin")
        
        let result = AudioProcess.visibleRows(from: [pWeChat, pHelper], tappedBundleIDs: [])
        
        print("Result count: \(result.count)")
        for p in result {
            print("  Selected representative: ID=\(p.audioObjectID), name='\(p.name)', bundleID='\(p.bundleID)'")
        }
        
        assert(result.count == 1, "Expected 1 representative")
        // Check if the bug is present: "Helper" wins over "微信"
        if result[0].name == "Helper" {
            print("WARNING/BUG: WeChat ('微信') was overridden by 'Helper' as representative!")
        } else {
            print("WeChat ('微信') won as representative.")
        }
        
        // Let's assert that the bug is indeed present (meaning "Helper" is chosen) to verify our theory.
        assert(result[0].name == "Helper", "Representative should have been Helper due to the uppercase check bug")
        print("PASS: testNonLatinLocalizedNameBug (verified that the uppercase heuristic is biased against non-Latin names)")
    }
    
    // Helper to build AudioProcess
    private static func proc(_ id: AudioObjectID, _ name: String, bundleID: String = "",
                             regular: Bool = true, output: Bool = false, icon: NSImage? = nil) -> AudioProcess {
        AudioProcess(audioObjectID: id, pid: pid_t(id & 0x7FFFFFFF), bundleID: bundleID, name: name,
                     icon: icon, isRunningOutput: output, isRegularApp: regular)
    }
    
    // Test 1: Transitive Grouping Conflict
    // A matches B by name, B matches C by bundle ID. Does A group with C?
    // If so, does it collapse completely unrelated applications?
    static func testTransitiveGroupingConflict() {
        print("Running: testTransitiveGroupingConflict...")
        // A: name="Helper", bundleID="com.foo.helper" -> normalizes to "com.foo"
        // B: name="Helper", bundleID="com.bar.app" -> normalizes to "com.bar.app"
        // C: name="App", bundleID="com.bar.app" -> normalizes to "com.bar.app"
        let pA = proc(1, "Helper", bundleID: "com.foo.helper")
        let pB = proc(2, "Helper", bundleID: "com.bar.app")
        let pC = proc(3, "App", bundleID: "com.bar.app")
        
        let result = AudioProcess.visibleRows(from: [pA, pB, pC], tappedBundleIDs: [])
        
        // They are all candidates because regular=true by default.
        // pA has bundleID "com.foo", name "Helper"
        // pB has bundleID "com.bar.app", name "Helper"
        // pC has bundleID "com.bar.app", name "App"
        // Pair (pA, pB): same name "Helper" -> union
        // Pair (pB, pC): same bundleID "com.bar.app" -> union
        // Pair (pA, pC): no direct match, but by transitivity they are grouped!
        
        print("Result count: \(result.count)")
        for p in result {
            print("  Selected representative: ID=\(p.audioObjectID), name='\(p.name)', bundleID='\(p.bundleID)'")
        }
        
        // Assert that they are unioned into a single group, which is a bug because com.foo and com.bar are different apps.
        assert(result.count == 1, "Expected transitive union to group all 3 processes into 1")
        print("PASS: testTransitiveGroupingConflict (verified that transitive grouping merges different apps)")
    }
    
    // Test 2: Overlapping Groups with Real-World Helpers
    // MS Teams and Google Chrome helper processes both named "helper" or "Renderer"
    static func testOverlappingGroupsWithHelpers() {
        print("Running: testOverlappingGroupsWithHelpers...")
        // Microsoft Teams: name="Microsoft Teams", bundleID="com.microsoft.teams"
        // Teams Helper: name="helper", bundleID="com.microsoft.teams.helper" -> normalizes to "com.microsoft.teams"
        // Chrome Helper: name="helper", bundleID="com.google.chrome.helper" -> normalizes to "com.google.chrome"
        // Google Chrome: name="Google Chrome", bundleID="com.google.chrome"
        let teams = proc(1, "Microsoft Teams", bundleID: "com.microsoft.teams")
        let teamsHelper = proc(2, "helper", bundleID: "com.microsoft.teams.helper")
        let chromeHelper = proc(3, "helper", bundleID: "com.google.chrome.helper")
        let chrome = proc(4, "Google Chrome", bundleID: "com.google.chrome")
        
        let result = AudioProcess.visibleRows(from: [teams, teamsHelper, chromeHelper, chrome], tappedBundleIDs: [])
        
        print("Result count: \(result.count)")
        for p in result {
            print("  Selected representative: ID=\(p.audioObjectID), name='\(p.name)', bundleID='\(p.bundleID)'")
        }
        
        // If they transitive-group, they will collapse into 1 row!
        // Teams (com.microsoft.teams) <-> TeamsHelper (com.microsoft.teams) : same bundleID
        // TeamsHelper (helper) <-> ChromeHelper (helper) : same name "helper"
        // ChromeHelper (com.google.chrome) <-> Chrome (com.google.chrome) : same bundleID
        // Therefore all 4 group together!
        assert(result.count == 1, "Expected all 4 processes to merge into 1 due to helper name overlap")
        print("PASS: testOverlappingGroupsWithHelpers (verified overlap bug where Teams and Chrome merge)")
    }
    
    // Test 3: Heuristic Total Order
    // Verify that the order is strict, total, transitive, and stable.
    static func testHeuristicTotalOrder() {
        print("Running: testHeuristicTotalOrder...")
        
        // We will generate different permutations and verify the representative remains identical.
        let img = NSImage()
        let p1 = proc(1, "App", bundleID: "com.a", regular: false, output: false)
        let p2 = proc(2, "App", bundleID: "com.a", regular: true, output: false) // regular app
        let p3 = proc(3, "App", bundleID: "com.a", regular: true, output: true)  // regular + output
        let p4 = proc(4, "App", bundleID: "com.a", regular: true, output: true, icon: img) // regular + output + icon
        let p5 = proc(5, "App", bundleID: "com.a", regular: true, output: true, icon: img) // regular + output + icon + lower ID
        
        let group = [p1, p2, p3, p4, p5]
        
        // Test all permutations of the group
        func permute<T>(_ array: [T]) -> [[T]] {
            guard array.count > 0 else { return [[]] }
            var result: [[T]] = []
            for i in 0..<array.count {
                var copy = array
                let elem = copy.remove(at: i)
                let subperms = permute(copy)
                for sub in subperms {
                    result.append([elem] + sub)
                }
            }
            return result
        }
        
        let permutations = permute(group)
        print("Checking \(permutations.count) permutations of representative selection...")
        
        var firstRepID: AudioObjectID? = nil
        for perm in permutations {
            let res = AudioProcess.visibleRows(from: perm, tappedBundleIDs: [])
            assert(res.count == 1, "Expected exactly 1 representative")
            let rep = res[0]
            if let firstID = firstRepID {
                assert(rep.audioObjectID == firstID, "Representative selection is unstable across permutations! Got ID \(rep.audioObjectID), expected \(firstID)")
            } else {
                firstRepID = rep.audioObjectID
                // According to our priority rules:
                // p4 and p5 both have output=true, regular=true, icon!=nil, localized name, non-empty bundleID.
                // Fallback prioritizes lower audioObjectID, so p4 (ID 4) should be better than p5 (ID 5).
                // Thus p4 must be the representative!
                assert(rep.audioObjectID == 4, "Expected representative to be p4 (ID 4), but got ID \(rep.audioObjectID)")
            }
        }
        print("PASS: testHeuristicTotalOrder (verified stable maximum selection under strict total order)")
    }
    
    // Test 4: Edge Cases & Boundary Values
    static func testEdgeCases() {
        print("Running: testEdgeCases...")
        
        // Empty names and bundle IDs
        let pEmptyName = proc(1, "", bundleID: "com.empty.name")
        let pEmptyBundle = proc(2, "NoBundle", bundleID: "")
        let pEmptyBoth = proc(3, "", bundleID: "")
        
        let resEmpty = AudioProcess.visibleRows(from: [pEmptyName, pEmptyBundle, pEmptyBoth], tappedBundleIDs: [])
        print("Empty inputs result count: \(resEmpty.count)")
        // Empty bundle IDs should not group together if their names are different.
        // Empty names should not group together if their bundle IDs are different.
        // Wait, pEmptyBoth has name="" and bundleID="".
        // Does pEmptyBoth group with pEmptyName?
        // Pair (pEmptyName, pEmptyBoth): both have name="" -> sameName=true -> union!
        // Pair (pEmptyBundle, pEmptyBoth): both have bundleID="" -> wait, sameBundle checks `!a.bundleID.isEmpty && !b.bundleID.isEmpty`, so empty bundle IDs do NOT match!
        // But sameName for pEmptyName (name="") and pEmptyBoth (name="") matches because both are "".
        // Let's verify:
        // pEmptyName (name="", bundleID="com.empty.name")
        // pEmptyBoth (name="", bundleID="")
        // Since name is same (""), they union.
        // Representative of the union of pEmptyName and pEmptyBoth:
        // pEmptyName has non-empty bundleID, so it is a better representative.
        // Thus, the result should have:
        // - "NoBundle" (pEmptyBundle)
        // - Representative of {pEmptyName, pEmptyBoth} (which is pEmptyName, name="")
        assert(resEmpty.count == 2, "Expected 2 representatives, got \(resEmpty.count)")
        
        // Unicode and Case Sensitivity
        let pUpper = proc(4, "SPOTIFY", bundleID: "COM.SPOTIFY.CLIENT")
        let pLower = proc(5, "spotify", bundleID: "com.spotify.client")
        let resCase = AudioProcess.visibleRows(from: [pUpper, pLower], tappedBundleIDs: [])
        assert(resCase.count == 1, "Expected case-insensitive grouping to yield 1 row, got \(resCase.count)")
        
        // Negative / Large IDs
        let pHuge = proc(4294967295, "Huge", bundleID: "com.huge") // Max UInt32
        let pZero = proc(0, "Zero", bundleID: "com.zero")
        let resIds = AudioProcess.visibleRows(from: pHuge.audioObjectID != pZero.audioObjectID ? [pHuge, pZero] : [pZero], tappedBundleIDs: [])
        assert(resIds.count == 2, "Expected 2 rows for huge and zero IDs")
        
        print("PASS: testEdgeCases")
    }
    
    // Test 5: Performance Stress & Memory Bottleneck Verification
    static func testPerformanceStress() {
        print("Running: testPerformanceStress...")
        
        // Let's check execution time for different candidate counts.
        // We will generate unique processes to prevent deduplication and force the maximum loops.
        func generateUniqueProcesses(count: Int) -> [AudioProcess] {
            var arr: [AudioProcess] = []
            for i in 1...count {
                arr.append(proc(AudioObjectID(i), "App-\(i)", bundleID: "com.app.\(i)"))
            }
            return arr
        }
        
        let sizes = [100, 500, 1000, 2000]
        for size in sizes {
            let list = generateUniqueProcesses(count: size)
            
            let start = DispatchTime.now()
            let result = AudioProcess.visibleRows(from: list, tappedBundleIDs: [])
            let end = DispatchTime.now()
            
            let nanoTime = end.uptimeNanoseconds - start.uptimeNanoseconds
            let timeInterval = Double(nanoTime) / 1_000_000_000
            
            print("  Size N=\(size): execution time = \(String(format: "%.4f", timeInterval)) seconds (result count = \(result.count))")
            
            // For N=2000, if it takes more than 1-2 seconds, it is a significant issue.
            // On modern Mac, N=1000 might take 0.1-0.5s, but N=2000 is quadratic so it will be 4x slower.
        }
        
        print("PASS: testPerformanceStress")
    }
}
