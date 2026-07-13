import XCTest
import Foundation
import CoreAudio
@testable import Core

final class AudioProcessTests: XCTestCase {
    /// Build an AudioProcess with sensible defaults for the field under test.
    private func proc(_ id: AudioObjectID, _ name: String, bundleID: String = "",
                      regular: Bool = true, output: Bool = false) -> AudioProcess {
        AudioProcess(audioObjectID: id, pid: pid_t(id), bundleID: bundleID, name: name,
                     icon: nil, isRunningOutput: output, isRegularApp: regular)
    }

    func testSilentRegularShows() {
        let rows = AudioProcess.visibleRows(
            from: [proc(1, "Spotify", bundleID: "com.spotify.client", regular: true, output: false)],
            tappedBundleIDs: []
        )
        XCTAssertEqual(rows.map(\.name), ["Spotify"])
    }

    func testDaemonsExcluded() {
        let rows = AudioProcess.visibleRows(
            from: [
                proc(1, "audiomxd", bundleID: "com.apple.audiomxd", regular: false, output: false),
                proc(2, "Spotify", bundleID: "com.spotify.client", regular: true)
            ],
            tappedBundleIDs: []
        )
        XCTAssertEqual(rows.map(\.name), ["Spotify"])
    }

    func testDedupesMultiProcess() {
        let rows = AudioProcess.visibleRows(
            from: [
                proc(1, "Google Chrome", bundleID: "com.google.Chrome", regular: true),
                proc(2, "Google Chrome", bundleID: "com.google.Chrome.helper", regular: true),
                proc(3, "Google Chrome", bundleID: "com.google.Chrome.helper", regular: true)
            ],
            tappedBundleIDs: []
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].name, "Google Chrome")
    }

    func testPrefersOutputtingRepresentative() {
        let rows = AudioProcess.visibleRows(
            from: [
                proc(1, "Google Chrome", bundleID: "com.google.Chrome", regular: true, output: false),
                proc(2, "Google Chrome", bundleID: "com.google.Chrome.helper", regular: true, output: true)
            ],
            tappedBundleIDs: []
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].bundleID, "com.google.Chrome")
        XCTAssertTrue(rows[0].isRunningOutput)
    }

    func testNormalizeBundleID() {
        XCTAssertEqual(AudioProcess.normalizeBundleID("com.google.Chrome"), "com.google.Chrome")
        XCTAssertEqual(AudioProcess.normalizeBundleID("com.google.Chrome.helper"), "com.google.Chrome")
        XCTAssertEqual(AudioProcess.normalizeBundleID("com.google.Chrome.helper.renderer"), "com.google.Chrome")
        XCTAssertEqual(AudioProcess.normalizeBundleID("org.chromium.Chromium.helper.renderer"), "org.chromium.Chromium")
        XCTAssertEqual(AudioProcess.normalizeBundleID("com.hnc.Discord.Helper"), "com.hnc.Discord")
        XCTAssertEqual(AudioProcess.normalizeBundleID("com.spotify.client.helper"), "com.spotify.client")
        XCTAssertEqual(AudioProcess.normalizeBundleID(""), "")
    }

    func testTappedShowsRegardless() {
        let rows = AudioProcess.visibleRows(
            from: [proc(1, "Weird", bundleID: "com.weird.bg", regular: false, output: false)],
            tappedBundleIDs: ["com.weird.bg"]
        )
        XCTAssertEqual(rows.map(\.name), ["Weird"])
    }

    func testSortedByName() {
        let rows = AudioProcess.visibleRows(
            from: [
                proc(1, "Spotify", bundleID: "com.spotify.client"),
                proc(2, "Discord", bundleID: "com.hnc.Discord"),
                proc(3, "google chrome", bundleID: "com.google.Chrome")
            ],
            tappedBundleIDs: []
        )
        XCTAssertEqual(rows.map(\.name), ["Discord", "google chrome", "Spotify"])
    }

    func testBundleIDGroupingWithDifferentNameCasings() {
        // Grouping by bundle ID with different name casings
        let rowsByBundleID = AudioProcess.visibleRows(
            from: [
                proc(1, "Finder", bundleID: "com.apple.finder", regular: true),
                proc(2, "finder", bundleID: "com.apple.Finder", regular: true)
            ],
            tappedBundleIDs: []
        )
        XCTAssertEqual(rowsByBundleID.count, 1)
        // Heuristic 4 (localized name "Finder") should make "Finder" win over "finder"
        XCTAssertEqual(rowsByBundleID[0].name, "Finder")

        // Grouping by name when bundle ID is empty
        let rowsByName = AudioProcess.visibleRows(
            from: [
                proc(3, "Finder", bundleID: "", regular: true),
                proc(4, "finder", bundleID: "", regular: true)
            ],
            tappedBundleIDs: []
        )
        XCTAssertEqual(rowsByName.count, 1)
        XCTAssertEqual(rowsByName[0].name, "Finder")
    }

    func testRepresentativeHeuristics() {
        // Heuristic 1: Prioritize processes outputting audio
        let rows1 = AudioProcess.visibleRows(
            from: [
                proc(1, "TestApp", bundleID: "com.test", regular: true, output: false),
                proc(2, "TestApp", bundleID: "com.test", regular: true, output: true)
            ],
            tappedBundleIDs: []
        )
        XCTAssertEqual(rows1.count, 1)
        XCTAssertTrue(rows1[0].isRunningOutput)
        XCTAssertEqual(rows1[0].audioObjectID, 2)

        // Heuristic 2: Prioritize regular applications
        let rows2 = AudioProcess.visibleRows(
            from: [
                proc(1, "TestApp", bundleID: "com.test", regular: false, output: false),
                proc(2, "TestApp", bundleID: "com.test", regular: true, output: false)
            ],
            tappedBundleIDs: []
        )
        XCTAssertEqual(rows2.count, 1)
        XCTAssertTrue(rows2[0].isRegularApp)
        XCTAssertEqual(rows2[0].audioObjectID, 2)

        // Heuristic 3: Prioritize processes with icons
        let img = NSImage()
        let rows3 = AudioProcess.visibleRows(
            from: [
                AudioProcess(audioObjectID: 1, pid: 1, bundleID: "com.test", name: "TestApp", icon: nil, isRunningOutput: false, isRegularApp: true),
                AudioProcess(audioObjectID: 2, pid: 2, bundleID: "com.test", name: "TestApp", icon: img, isRunningOutput: false, isRegularApp: true)
            ],
            tappedBundleIDs: []
        )
        XCTAssertEqual(rows3.count, 1)
        XCTAssertNotNil(rows3[0].icon)
        XCTAssertEqual(rows3[0].audioObjectID, 2)

        // Heuristic 4: Prioritize localized names
        let rows4 = AudioProcess.visibleRows(
            from: [
                proc(1, "process test", bundleID: "com.test", regular: true, output: false),
                proc(2, "TestApp", bundleID: "com.test", regular: true, output: false)
            ],
            tappedBundleIDs: []
        )
        XCTAssertEqual(rows4.count, 1)
        XCTAssertEqual(rows4[0].name, "TestApp")

        // Heuristic 5 (fallback A): Prioritize lower audioObjectID
        let rows5 = AudioProcess.visibleRows(
            from: [
                proc(2, "TestApp", bundleID: "com.test", regular: true, output: false),
                proc(1, "TestApp", bundleID: "com.test", regular: true, output: false)
            ],
            tappedBundleIDs: []
        )
        XCTAssertEqual(rows5.count, 1)
        XCTAssertEqual(rows5[0].audioObjectID, 1)

        // Heuristic 5 (fallback B): Prioritize lower PID
        // To construct two with same audioObjectID but different PIDs:
        let rows6 = AudioProcess.visibleRows(
            from: [
                AudioProcess(audioObjectID: 1, pid: 2, bundleID: "com.test", name: "TestApp", icon: nil, isRunningOutput: false, isRegularApp: true),
                AudioProcess(audioObjectID: 1, pid: 1, bundleID: "com.test", name: "TestApp", icon: nil, isRunningOutput: false, isRegularApp: true)
            ],
            tappedBundleIDs: []
        )
        XCTAssertEqual(rows6.count, 1)
        XCTAssertEqual(rows6[0].pid, 1)
    }

    func testDeduplicationEmptyBundleIDSameName() {
        let rows = AudioProcess.visibleRows(
            from: [
                proc(1, "finder", bundleID: "", regular: true),
                proc(2, "Finder", bundleID: "com.apple.finder", regular: true)
            ],
            tappedBundleIDs: []
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].name, "Finder")
        XCTAssertEqual(rows[0].bundleID, "com.apple.finder")
    }

    func testNoTransitiveGroupingDifferentBundleIDs() {
        let rows = AudioProcess.visibleRows(
            from: [
                proc(1, "Foo", bundleID: "com.apple.foo"),
                proc(2, "Foo", bundleID: ""),
                proc(3, "Foo", bundleID: "com.apple.bar")
            ],
            tappedBundleIDs: []
        )
        XCTAssertEqual(rows.count, 2)
    }

    func testNormalizeBundleIDMidComponentHelper() {
        XCTAssertEqual(AudioProcess.normalizeBundleID("com.example.helper.app"), "com.example.helper.app")
        XCTAssertEqual(AudioProcess.normalizeBundleID("com.example.app.helper"), "com.example.app")
    }

    func testNoEmptyNameCollision() {
        let rows = AudioProcess.visibleRows(
            from: [
                proc(1, "", bundleID: "com.apple.foo"),
                proc(2, "", bundleID: "com.apple.bar")
            ],
            tappedBundleIDs: []
        )
        XCTAssertEqual(rows.count, 2)
    }

    func testCJKAndNumericLocalizationPrioritized() {
        let rows = AudioProcess.visibleRows(
            from: [
                proc(1, "com.example.music", bundleID: "com.example"),
                proc(2, "音乐", bundleID: "com.example")
            ],
            tappedBundleIDs: []
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].name, "音乐")

        let rows2 = AudioProcess.visibleRows(
            from: [
                proc(3, "com.agilebits.onepassword", bundleID: "com.1password"),
                proc(4, "1Password", bundleID: "com.1password")
            ],
            tappedBundleIDs: []
        )
        XCTAssertEqual(rows2.count, 1)
        XCTAssertEqual(rows2[0].name, "1Password")
    }

    func testGenericHelperNameHijacking() {
        // WeChat ("微信", ID=2) vs capitalized "Helper" (ID=1)
        let pWeChat = proc(2, "微信", bundleID: "com.tencent.xin")
        let pHelper = proc(1, "Helper", bundleID: "com.tencent.xin")
        let result1 = AudioProcess.visibleRows(from: [pWeChat, pHelper], tappedBundleIDs: [])
        XCTAssertEqual(result1.count, 1)
        XCTAssertEqual(result1[0].name, "微信")

        // Slack ("Slack", ID=2) vs capitalized "Helper" (ID=1)
        let pSlack = proc(2, "Slack", bundleID: "com.tinyspeck.slackmacgap")
        let pHelper2 = proc(1, "Helper", bundleID: "com.tinyspeck.slackmacgap")
        let result2 = AudioProcess.visibleRows(from: [pSlack, pHelper2], tappedBundleIDs: [])
        XCTAssertEqual(result2.count, 1)
        XCTAssertEqual(result2[0].name, "Slack")
    }

    func testIteration4EdgeCases() {
        // 1. Lowercase Main App Name Hijacking (lowercase app name vs capitalized helper name)
        let rowsLowercaseApp = AudioProcess.visibleRows(
            from: [
                proc(2, "spotify", bundleID: "com.spotify.client", regular: true),
                proc(1, "Spotify Helper", bundleID: "com.spotify.client", regular: true)
            ],
            tappedBundleIDs: []
        )
        XCTAssertEqual(rowsLowercaseApp.count, 1)
        XCTAssertEqual(rowsLowercaseApp[0].name, "spotify")
        
        // WeChat vs capitalized WeChat Helper with lower ID
        let resultWeChat = AudioProcess.visibleRows(
            from: [
                proc(2, "wechat", bundleID: "com.tencent.xin", regular: true),
                proc(1, "WeChat Helper", bundleID: "com.tencent.xin", regular: true)
            ],
            tappedBundleIDs: []
        )
        XCTAssertEqual(resultWeChat.count, 1)
        XCTAssertEqual(resultWeChat[0].name, "wechat")

        // 2. Substring Helper Name Check
        let rowsHelper = AudioProcess.visibleRows(
            from: [
                proc(2, "Google Chrome", bundleID: "com.google.Chrome", regular: true),
                proc(1, "Chrome Helper", bundleID: "com.google.Chrome", regular: true)
            ],
            tappedBundleIDs: []
        )
        XCTAssertEqual(rowsHelper.count, 1)
        XCTAssertEqual(rowsHelper[0].name, "Google Chrome")

        // 3. Short Bundle ID collapse (prevent TLD collapse)
        XCTAssertEqual(AudioProcess.normalizeBundleID("com.helper"), "com.helper")
        XCTAssertEqual(AudioProcess.normalizeBundleID("com.renderer"), "com.renderer")
        XCTAssertEqual(AudioProcess.normalizeBundleID("com.google.Chrome.helper"), "com.google.Chrome")
        XCTAssertEqual(AudioProcess.normalizeBundleID("helper"), "helper")
        
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
        XCTAssertEqual(procWithWhitespace.name, "Spotify")
        XCTAssertEqual(procWithWhitespace.bundleID, "com.spotify.client")
        
        // 5. Case-sensitive prefix check for "process " case-insensitively
        let rowsProcessPrefix = AudioProcess.visibleRows(
            from: [
                proc(2, "Spotify", bundleID: "com.spotify.client", regular: true),
                proc(1, "PROCESS 123", bundleID: "com.spotify.client", regular: true)
            ],
            tappedBundleIDs: []
        )
        XCTAssertEqual(rowsProcessPrefix.count, 1)
        XCTAssertEqual(rowsProcessPrefix[0].name, "Spotify")
        
        // 6. Whitespace-only name hijacking
        let rowsWhitespaceOnly = AudioProcess.visibleRows(
            from: [
                proc(2, "Spotify", bundleID: "com.spotify.client", regular: true),
                proc(1, "   \n   ", bundleID: "com.spotify.client", regular: true)
            ],
            tappedBundleIDs: []
        )
        XCTAssertEqual(rowsWhitespaceOnly.count, 1)
        XCTAssertEqual(rowsWhitespaceOnly[0].name, "Spotify")

        // 7. Prefix bundle ID compatibility (e.g. Discord helper plugin)
        let rowsPrefixCompat = AudioProcess.visibleRows(
            from: [
                proc(2, "Discord", bundleID: "com.hnc.Discord", regular: true),
                proc(1, "Discord", bundleID: "com.hnc.Discord.helper.Plugin", regular: true)
            ],
            tappedBundleIDs: []
        )
        XCTAssertEqual(rowsPrefixCompat.count, 1)
        XCTAssertEqual(rowsPrefixCompat[0].bundleID, "com.hnc.Discord")
    }

    func testDeduplicationEdgeCasesIteration5() {
        // 1. Lowercase-first App Name Hijacking (spotify vs Spotify Networking)
        let rows1 = AudioProcess.visibleRows(
            from: [
                proc(2, "spotify", bundleID: "com.spotify.client"),
                proc(1, "Spotify Networking", bundleID: "com.spotify.client")
            ],
            tappedBundleIDs: []
        )
        XCTAssertEqual(rows1.count, 1)
        XCTAssertEqual(rows1[0].name, "spotify")
        
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
        XCTAssertEqual(rows2.count, 1)
        XCTAssertEqual(rows2[0].name, "spotify")
        
        // 3. Unrecognized Capitalized Helper Tie-breaker Hijacking (Spotify vs Spotify Networking)
        let rows3 = AudioProcess.visibleRows(
            from: [
                proc(2, "Spotify", bundleID: "com.spotify.client"),
                proc(1, "Spotify Networking", bundleID: "com.spotify.client")
            ],
            tappedBundleIDs: []
        )
        XCTAssertEqual(rows3.count, 1)
        XCTAssertEqual(rows3[0].name, "Spotify")
        
        // 4. App Name Containing Dot Hijacking (Paint.NET vs process 123)
        let rows4 = AudioProcess.visibleRows(
            from: [
                proc(2, "Paint.NET", bundleID: "com.paint.net"),
                proc(1, "process 123", bundleID: "com.paint.net")
            ],
            tappedBundleIDs: []
        )
        XCTAssertEqual(rows4.count, 1)
        XCTAssertEqual(rows4[0].name, "Paint.NET")
        
        // 5. Spotify vs Spot (Unrelated Shorter Prefix Name Hijacking)
        let rows5 = AudioProcess.visibleRows(
            from: [
                proc(2, "Spotify", bundleID: "com.spotify.client"),
                proc(1, "Spot", bundleID: "com.spotify.client")
            ],
            tappedBundleIDs: []
        )
        XCTAssertEqual(rows5.count, 1)
        XCTAssertEqual(rows5[0].name, "Spotify")

        // 6. Renderer's Toolkit vs renderer (Over-aggressive Helper Keyword Penalty)
        let rows6 = AudioProcess.visibleRows(
            from: [
                proc(2, "Renderer's Toolkit", bundleID: "com.toolkit.renderer"),
                proc(1, "renderer", bundleID: "com.toolkit.renderer")
            ],
            tappedBundleIDs: []
        )
        XCTAssertEqual(rows6.count, 1)
        XCTAssertEqual(rows6[0].name, "Renderer's Toolkit")

        // 7. Google Chrome vs chrome (No-Prefix Matches)
        let rows7 = AudioProcess.visibleRows(
            from: [
                proc(2, "Google Chrome", bundleID: "com.google.chrome"),
                proc(1, "chrome", bundleID: "com.google.chrome")
            ],
            tappedBundleIDs: []
        )
        XCTAssertEqual(rows7.count, 1)
        XCTAssertEqual(rows7[0].name, "Google Chrome")

        // 8. Mixed-case bundle ID matching
        let rows8 = AudioProcess.visibleRows(
            from: [
                proc(2, "Spotify", bundleID: "com.Spotify.client"),
                proc(1, "Spot", bundleID: "com.spotify.Client")
            ],
            tappedBundleIDs: []
        )
        XCTAssertEqual(rows8.count, 1)
        XCTAssertEqual(rows8[0].name, "Spotify")
    }
}
