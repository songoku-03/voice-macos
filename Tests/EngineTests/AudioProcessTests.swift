import Testing
import Foundation
import AppKit
import CoreAudio
@testable import Core

@Suite struct AudioProcessTests {
    /// Build an AudioProcess with sensible defaults for the field under test.
    private func proc(_ id: AudioObjectID, _ name: String, bundleID: String = "",
                      regular: Bool = true, output: Bool = false) -> AudioProcess {
        AudioProcess(audioObjectID: id, pid: pid_t(id), bundleID: bundleID, name: name,
                     icon: nil, isRunningOutput: output, isRegularApp: regular)
    }

    @Test func silentRegularShows() {
        let rows = AudioProcess.visibleRows(
            from: [proc(1, "Spotify", bundleID: "com.spotify.client", regular: true, output: false)],
            tappedBundleIDs: []
        )
        #expect(rows.map(\.name) == ["Spotify"])
    }

    @Test func daemonsExcluded() {
        let rows = AudioProcess.visibleRows(
            from: [
                proc(1, "audiomxd", bundleID: "com.apple.audiomxd", regular: false, output: false),
                proc(2, "Spotify", bundleID: "com.spotify.client", regular: true)
            ],
            tappedBundleIDs: []
        )
        #expect(rows.map(\.name) == ["Spotify"])
    }

    @Test func dedupesMultiProcess() {
        let rows = AudioProcess.visibleRows(
            from: [
                proc(1, "Google Chrome", bundleID: "com.google.Chrome", regular: true),
                proc(2, "Google Chrome", bundleID: "com.google.Chrome.helper", regular: true),
                proc(3, "Google Chrome", bundleID: "com.google.Chrome.helper", regular: true)
            ],
            tappedBundleIDs: []
        )
        #expect(rows.count == 1)
        #expect(rows[0].name == "Google Chrome")
    }

    @Test func prefersOutputtingRepresentative() {
        let rows = AudioProcess.visibleRows(
            from: [
                proc(1, "Google Chrome", bundleID: "com.google.Chrome", regular: true, output: false),
                proc(2, "Google Chrome", bundleID: "com.google.Chrome.helper", regular: true, output: true)
            ],
            tappedBundleIDs: []
        )
        #expect(rows.count == 1)
        #expect(rows[0].bundleID == "com.google.Chrome")
        #expect(rows[0].isRunningOutput)
    }

    @Test func normalizeBundleID() {
        #expect(AudioProcess.normalizeBundleID("com.google.Chrome") == "com.google.Chrome")
        #expect(AudioProcess.normalizeBundleID("com.google.Chrome.helper") == "com.google.Chrome")
        #expect(AudioProcess.normalizeBundleID("com.google.Chrome.helper.renderer") == "com.google.Chrome")
        #expect(AudioProcess.normalizeBundleID("org.chromium.Chromium.helper.renderer") == "org.chromium.Chromium")
        #expect(AudioProcess.normalizeBundleID("com.hnc.Discord.Helper") == "com.hnc.Discord")
        #expect(AudioProcess.normalizeBundleID("com.spotify.client.helper") == "com.spotify.client")
        #expect(AudioProcess.normalizeBundleID("") == "")
    }

    @Test func tappedShowsRegardless() {
        let rows = AudioProcess.visibleRows(
            from: [proc(1, "Weird", bundleID: "com.weird.bg", regular: false, output: false)],
            tappedBundleIDs: ["com.weird.bg"]
        )
        #expect(rows.map(\.name) == ["Weird"])
    }

    @Test func sortedByName() {
        let rows = AudioProcess.visibleRows(
            from: [
                proc(1, "Spotify", bundleID: "com.spotify.client"),
                proc(2, "Discord", bundleID: "com.hnc.Discord"),
                proc(3, "google chrome", bundleID: "com.google.Chrome")
            ],
            tappedBundleIDs: []
        )
        #expect(rows.map(\.name) == ["Discord", "google chrome", "Spotify"])
    }

    @Test func bundleIDGroupingWithDifferentNameCasings() {
        // Grouping by bundle ID with different name casings
        let rowsByBundleID = AudioProcess.visibleRows(
            from: [
                proc(1, "Finder", bundleID: "com.apple.finder", regular: true),
                proc(2, "finder", bundleID: "com.apple.Finder", regular: true)
            ],
            tappedBundleIDs: []
        )
        #expect(rowsByBundleID.count == 1)
        // Heuristic 4 (localized name "Finder") should make "Finder" win over "finder"
        #expect(rowsByBundleID[0].name == "Finder")

        // Grouping by name when bundle ID is empty
        let rowsByName = AudioProcess.visibleRows(
            from: [
                proc(3, "Finder", bundleID: "", regular: true),
                proc(4, "finder", bundleID: "", regular: true)
            ],
            tappedBundleIDs: []
        )
        #expect(rowsByName.count == 1)
        #expect(rowsByName[0].name == "Finder")
    }

    @Test func representativeHeuristics() {
        // Heuristic 1: Prioritize processes outputting audio
        let rows1 = AudioProcess.visibleRows(
            from: [
                proc(1, "TestApp", bundleID: "com.test", regular: true, output: false),
                proc(2, "TestApp", bundleID: "com.test", regular: true, output: true)
            ],
            tappedBundleIDs: []
        )
        #expect(rows1.count == 1)
        #expect(rows1[0].isRunningOutput)
        #expect(rows1[0].audioObjectID == 2)

        // Heuristic 2: Prioritize regular applications
        let rows2 = AudioProcess.visibleRows(
            from: [
                proc(1, "TestApp", bundleID: "com.test", regular: false, output: false),
                proc(2, "TestApp", bundleID: "com.test", regular: true, output: false)
            ],
            tappedBundleIDs: []
        )
        #expect(rows2.count == 1)
        #expect(rows2[0].isRegularApp)
        #expect(rows2[0].audioObjectID == 2)

        // Heuristic 3: Prioritize processes with icons
        let img = NSImage()
        let rows3 = AudioProcess.visibleRows(
            from: [
                AudioProcess(audioObjectID: 1, pid: 1, bundleID: "com.test", name: "TestApp", icon: nil, isRunningOutput: false, isRegularApp: true),
                AudioProcess(audioObjectID: 2, pid: 2, bundleID: "com.test", name: "TestApp", icon: img, isRunningOutput: false, isRegularApp: true)
            ],
            tappedBundleIDs: []
        )
        #expect(rows3.count == 1)
        #expect(rows3[0].icon != nil)
        #expect(rows3[0].audioObjectID == 2)

        // Heuristic 4: Prioritize localized names
        let rows4 = AudioProcess.visibleRows(
            from: [
                proc(1, "process test", bundleID: "com.test", regular: true, output: false),
                proc(2, "TestApp", bundleID: "com.test", regular: true, output: false)
            ],
            tappedBundleIDs: []
        )
        #expect(rows4.count == 1)
        #expect(rows4[0].name == "TestApp")

        // Heuristic 5 (fallback A): Prioritize lower audioObjectID
        let rows5 = AudioProcess.visibleRows(
            from: [
                proc(2, "TestApp", bundleID: "com.test", regular: true, output: false),
                proc(1, "TestApp", bundleID: "com.test", regular: true, output: false)
            ],
            tappedBundleIDs: []
        )
        #expect(rows5.count == 1)
        #expect(rows5[0].audioObjectID == 1)

        // Heuristic 5 (fallback B): Prioritize lower PID
        // To construct two with same audioObjectID but different PIDs:
        let rows6 = AudioProcess.visibleRows(
            from: [
                AudioProcess(audioObjectID: 1, pid: 2, bundleID: "com.test", name: "TestApp", icon: nil, isRunningOutput: false, isRegularApp: true),
                AudioProcess(audioObjectID: 1, pid: 1, bundleID: "com.test", name: "TestApp", icon: nil, isRunningOutput: false, isRegularApp: true)
            ],
            tappedBundleIDs: []
        )
        #expect(rows6.count == 1)
        #expect(rows6[0].pid == 1)
    }

    @Test func deduplicationEmptyBundleIDSameName() {
        let rows = AudioProcess.visibleRows(
            from: [
                proc(1, "finder", bundleID: "", regular: true),
                proc(2, "Finder", bundleID: "com.apple.finder", regular: true)
            ],
            tappedBundleIDs: []
        )
        #expect(rows.count == 1)
        #expect(rows[0].name == "Finder")
        #expect(rows[0].bundleID == "com.apple.finder")
    }

    @Test func deduplicationEmptyBundleIDSameNameCasing() {
        // Explicitly validating the case from the Acceptance Criteria:
        // (bundleID: "", name: "finder") merging with (bundleID: "com.apple.finder", name: "Finder")
        let rows = AudioProcess.visibleRows(
            from: [
                proc(1, "finder", bundleID: "", regular: true),
                proc(2, "Finder", bundleID: "com.apple.finder", regular: true)
            ],
            tappedBundleIDs: []
        )
        #expect(rows.count == 1)
        #expect(rows[0].name == "Finder")
        #expect(rows[0].bundleID == "com.apple.finder")
    }

    @Test func noTransitiveGroupingDifferentBundleIDs() {
        let rows = AudioProcess.visibleRows(
            from: [
                proc(1, "Foo", bundleID: "com.apple.foo"),
                proc(2, "Foo", bundleID: ""),
                proc(3, "Foo", bundleID: "com.apple.bar")
            ],
            tappedBundleIDs: []
        )
        #expect(rows.count == 2)
    }

    @Test func normalizeBundleIDMidComponentHelper() {
        #expect(AudioProcess.normalizeBundleID("com.example.helper.app") == "com.example.helper.app")
        #expect(AudioProcess.normalizeBundleID("com.example.app.helper") == "com.example.app")
    }

    @Test func noEmptyNameCollision() {
        let rows = AudioProcess.visibleRows(
            from: [
                proc(1, "", bundleID: "com.apple.foo"),
                proc(2, "", bundleID: "com.apple.bar")
            ],
            tappedBundleIDs: []
        )
        #expect(rows.count == 2)
    }

    @Test func cJKAndNumericLocalizationPrioritized() {
        let rows = AudioProcess.visibleRows(
            from: [
                proc(1, "com.example.music", bundleID: "com.example"),
                proc(2, "音乐", bundleID: "com.example")
            ],
            tappedBundleIDs: []
        )
        #expect(rows.count == 1)
        #expect(rows[0].name == "音乐")

        let rows2 = AudioProcess.visibleRows(
            from: [
                proc(3, "com.agilebits.onepassword", bundleID: "com.1password"),
                proc(4, "1Password", bundleID: "com.1password")
            ],
            tappedBundleIDs: []
        )
        #expect(rows2.count == 1)
        #expect(rows2[0].name == "1Password")
    }

    @Test func genericHelperNameHijacking() {
        // WeChat ("微信", ID=2) vs capitalized "Helper" (ID=1)
        let pWeChat = proc(2, "微信", bundleID: "com.tencent.xin")
        let pHelper = proc(1, "Helper", bundleID: "com.tencent.xin")
        let result1 = AudioProcess.visibleRows(from: [pWeChat, pHelper], tappedBundleIDs: [])
        #expect(result1.count == 1)
        #expect(result1[0].name == "微信")

        // Slack ("Slack", ID=2) vs capitalized "Helper" (ID=1)
        let pSlack = proc(2, "Slack", bundleID: "com.tinyspeck.slackmacgap")
        let pHelper2 = proc(1, "Helper", bundleID: "com.tinyspeck.slackmacgap")
        let result2 = AudioProcess.visibleRows(from: [pSlack, pHelper2], tappedBundleIDs: [])
        #expect(result2.count == 1)
        #expect(result2[0].name == "Slack")
    }

    @Test func iteration4EdgeCases() {
        // 1. Lowercase Main App Name Hijacking (lowercase app name vs capitalized helper name)
        let rowsLowercaseApp = AudioProcess.visibleRows(
            from: [
                proc(2, "spotify", bundleID: "com.spotify.client", regular: true),
                proc(1, "Spotify Helper", bundleID: "com.spotify.client", regular: true)
            ],
            tappedBundleIDs: []
        )
        #expect(rowsLowercaseApp.count == 1)
        #expect(rowsLowercaseApp[0].name == "spotify")
        
        // WeChat vs capitalized WeChat Helper with lower ID
        let resultWeChat = AudioProcess.visibleRows(
            from: [
                proc(2, "wechat", bundleID: "com.tencent.xin", regular: true),
                proc(1, "WeChat Helper", bundleID: "com.tencent.xin", regular: true)
            ],
            tappedBundleIDs: []
        )
        #expect(resultWeChat.count == 1)
        #expect(resultWeChat[0].name == "wechat")

        // 2. Substring Helper Name Check
        let rowsHelper = AudioProcess.visibleRows(
            from: [
                proc(2, "Google Chrome", bundleID: "com.google.Chrome", regular: true),
                proc(1, "Chrome Helper", bundleID: "com.google.Chrome", regular: true)
            ],
            tappedBundleIDs: []
        )
        #expect(rowsHelper.count == 1)
        #expect(rowsHelper[0].name == "Google Chrome")

        // 3. Short Bundle ID collapse (prevent TLD collapse)
        #expect(AudioProcess.normalizeBundleID("com.helper") == "com.helper")
        #expect(AudioProcess.normalizeBundleID("com.renderer") == "com.renderer")
        #expect(AudioProcess.normalizeBundleID("com.google.Chrome.helper") == "com.google.Chrome")
        #expect(AudioProcess.normalizeBundleID("helper") == "helper")
        
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
        #expect(procWithWhitespace.name == "Spotify")
        #expect(procWithWhitespace.bundleID == "com.spotify.client")
        
        // 5. Case-sensitive prefix check for "process " case-insensitively
        let rowsProcessPrefix = AudioProcess.visibleRows(
            from: [
                proc(2, "Spotify", bundleID: "com.spotify.client", regular: true),
                proc(1, "PROCESS 123", bundleID: "com.spotify.client", regular: true)
            ],
            tappedBundleIDs: []
        )
        #expect(rowsProcessPrefix.count == 1)
        #expect(rowsProcessPrefix[0].name == "Spotify")
        
        // 6. Whitespace-only name hijacking
        let rowsWhitespaceOnly = AudioProcess.visibleRows(
            from: [
                proc(2, "Spotify", bundleID: "com.spotify.client", regular: true),
                proc(1, "   \n   ", bundleID: "com.spotify.client", regular: true)
            ],
            tappedBundleIDs: []
        )
        #expect(rowsWhitespaceOnly.count == 1)
        #expect(rowsWhitespaceOnly[0].name == "Spotify")

        // 7. Prefix bundle ID compatibility (e.g. Discord helper plugin)
        let rowsPrefixCompat = AudioProcess.visibleRows(
            from: [
                proc(2, "Discord", bundleID: "com.hnc.Discord", regular: true),
                proc(1, "Discord", bundleID: "com.hnc.Discord.helper.Plugin", regular: true)
            ],
            tappedBundleIDs: []
        )
        #expect(rowsPrefixCompat.count == 1)
        #expect(rowsPrefixCompat[0].bundleID == "com.hnc.Discord")
    }

    @Test func deduplicationEdgeCasesIteration5() {
        // 1. Lowercase-first App Name Hijacking (spotify vs Spotify Networking)
        let rows1 = AudioProcess.visibleRows(
            from: [
                proc(2, "spotify", bundleID: "com.spotify.client"),
                proc(1, "Spotify Networking", bundleID: "com.spotify.client")
            ],
            tappedBundleIDs: []
        )
        #expect(rows1.count == 1)
        #expect(rows1[0].name == "spotify")
        
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
        #expect(rows2.count == 1)
        #expect(rows2[0].name == "spotify")
        
        // 3. Unrecognized Capitalized Helper Tie-breaker Hijacking (Spotify vs Spotify Networking)
        let rows3 = AudioProcess.visibleRows(
            from: [
                proc(2, "Spotify", bundleID: "com.spotify.client"),
                proc(1, "Spotify Networking", bundleID: "com.spotify.client")
            ],
            tappedBundleIDs: []
        )
        #expect(rows3.count == 1)
        #expect(rows3[0].name == "Spotify")
        
        // 4. App Name Containing Dot Hijacking (Paint.NET vs process 123)
        let rows4 = AudioProcess.visibleRows(
            from: [
                proc(2, "Paint.NET", bundleID: "com.paint.net"),
                proc(1, "process 123", bundleID: "com.paint.net")
            ],
            tappedBundleIDs: []
        )
        #expect(rows4.count == 1)
        #expect(rows4[0].name == "Paint.NET")
        
        // 5. Spotify vs Spot (Unrelated Shorter Prefix Name Hijacking)
        let rows5 = AudioProcess.visibleRows(
            from: [
                proc(2, "Spotify", bundleID: "com.spotify.client"),
                proc(1, "Spot", bundleID: "com.spotify.client")
            ],
            tappedBundleIDs: []
        )
        #expect(rows5.count == 1)
        #expect(rows5[0].name == "Spotify")

        // 6. Renderer's Toolkit vs renderer (Over-aggressive Helper Keyword Penalty)
        let rows6 = AudioProcess.visibleRows(
            from: [
                proc(2, "Renderer's Toolkit", bundleID: "com.toolkit.renderer"),
                proc(1, "renderer", bundleID: "com.toolkit.renderer")
            ],
            tappedBundleIDs: []
        )
        #expect(rows6.count == 1)
        #expect(rows6[0].name == "Renderer's Toolkit")

        // 7. Google Chrome vs chrome (No-Prefix Matches)
        let rows7 = AudioProcess.visibleRows(
            from: [
                proc(2, "Google Chrome", bundleID: "com.google.chrome"),
                proc(1, "chrome", bundleID: "com.google.chrome")
            ],
            tappedBundleIDs: []
        )
        #expect(rows7.count == 1)
        #expect(rows7[0].name == "Google Chrome")

        // 8. Mixed-case bundle ID matching
        let rows8 = AudioProcess.visibleRows(
            from: [
                proc(2, "Spotify", bundleID: "com.Spotify.client"),
                proc(1, "Spot", bundleID: "com.spotify.Client")
            ],
            tappedBundleIDs: []
        )
        #expect(rows8.count == 1)
        #expect(rows8[0].name == "Spotify")
    }
}
