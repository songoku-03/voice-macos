import Testing
import AVFoundation
import CoreAudio
import AppKit
@testable import Engine
@testable import Core

@MainActor
@Suite struct EmptyBundleIDFilteringTests {
    
    private func createTestManager() -> AudioEngineManager {
        let manager = AudioEngineManager()
        #if DEBUG
        manager.tapProvider = { _, _ in
            let dummyBuffer = RingBuffer(capacity: 64 * 1024)
            var dummyASBD = AudioStreamBasicDescription()
            dummyASBD.mSampleRate = 48000.0
            dummyASBD.mFormatID = kAudioFormatLinearPCM
            dummyASBD.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian
            dummyASBD.mBytesPerPacket = 8
            dummyASBD.mFramesPerPacket = 1
            dummyASBD.mBytesPerFrame = 8
            dummyASBD.mChannelsPerFrame = 2
            dummyASBD.mBitsPerChannel = 32
            return ([dummyBuffer], dummyASBD)
        }
        #endif
        return manager
    }
    
    private func getActivePIDs(from manager: AudioEngineManager) -> [String: Int32] {
        let mirror = Mirror(reflecting: manager)
        if let pidsRaw = mirror.descendant("_activePIDs") as? [String: Int32] {
            return pidsRaw
        }
        return [:]
    }

    private func getDesiredTappedBundleIDs(from manager: AudioEngineManager) -> Set<String> {
        let mirror = Mirror(reflecting: manager)
        for child in mirror.children {
            if child.label == "desiredTappedBundleIDs" || child.label == "_desiredTappedBundleIDs" {
                if let set = child.value as? Set<String> {
                    return set
                }
            }
        }
        return []
    }

    // 1. Entry point rejection test (Task 2.1)
    @Test func startAppTappingRejectsEmptyAndWhitespaceBundleIDs() throws {
        let originalUserDefaults = UserDefaults.standard.stringArray(forKey: "desiredTappedBundleIDs")
        defer {
            if let original = originalUserDefaults {
                UserDefaults.standard.set(original, forKey: "desiredTappedBundleIDs")
            } else {
                UserDefaults.standard.removeObject(forKey: "desiredTappedBundleIDs")
            }
        }

        let manager = createTestManager()
        let initialDesired = getDesiredTappedBundleIDs(from: manager)

        // Attempt tapping empty and whitespace-only bundle IDs
        manager.startAppTapping(bundleID: "", pid: 12345)
        manager.startAppTapping(bundleID: "   ", pid: 12345)
        manager.startAppTapping(bundleID: "\t\n  ", pid: 12345)

        // Verify activeNodes and activePIDs remain clean
        #expect(manager.activeNodes[""] == nil)
        #expect(manager.activeNodes["   "] == nil)
        #expect(manager.activeNodes["\t\n  "] == nil)
        #expect(getActivePIDs(from: manager)[""] == nil)
        #expect(getActivePIDs(from: manager)["   "] == nil)
        #expect(getActivePIDs(from: manager)["\t\n  "] == nil)

        // Verify desiredTappedBundleIDs was not mutated with invalid entries
        let currentDesired = getDesiredTappedBundleIDs(from: manager)
        #expect(currentDesired == initialDesired, "desiredTappedBundleIDs should not be mutated by invalid startAppTapping calls")
        #expect(!currentDesired.contains(""))
        #expect(!currentDesired.contains("   "))
        #expect(!currentDesired.contains("\t\n  "))

        // Verify valid bundleID still works
        manager.startAppTapping(bundleID: "com.apple.Safari", pid: 99999)
        #expect(manager.activeNodes["com.apple.Safari"] != nil)
        #expect(getActivePIDs(from: manager)["com.apple.Safari"] != nil)
        #expect(getDesiredTappedBundleIDs(from: manager).contains("com.apple.Safari"))
    }

    // 2. Cleanup on load test (Task 2.2)
    @Test func setupEngineFiltersInvalidBundleIDsAndPersistsCleanedSet() throws {
        let originalUserDefaults = UserDefaults.standard.stringArray(forKey: "desiredTappedBundleIDs")
        defer {
            if let original = originalUserDefaults {
                UserDefaults.standard.set(original, forKey: "desiredTappedBundleIDs")
            } else {
                UserDefaults.standard.removeObject(forKey: "desiredTappedBundleIDs")
            }
        }

        // Seed UserDefaults with a mix of valid and invalid bundle IDs
        let dirtyIDs = ["com.apple.Safari", "", "   ", "\t\n  ", "com.spotify.client"]
        UserDefaults.standard.set(dirtyIDs, forKey: "desiredTappedBundleIDs")

        // Instantiate manager, triggering setupEngine()
        let manager = createTestManager()

        // Verify in-memory set contains only valid bundle IDs
        let loadedDesired = getDesiredTappedBundleIDs(from: manager)
        #expect(loadedDesired == Set(["com.apple.Safari", "com.spotify.client"]))
        #expect(!loadedDesired.contains(""))
        #expect(!loadedDesired.contains("   "))
        #expect(!loadedDesired.contains("\t\n  "))

        // Verify cleaned set was persisted back to UserDefaults
        let persistedIDs = UserDefaults.standard.stringArray(forKey: "desiredTappedBundleIDs") ?? []
        #expect(Set(persistedIDs) == Set(["com.apple.Safari", "com.spotify.client"]))
        #expect(!persistedIDs.contains(""))
        #expect(!persistedIDs.contains("   "))
        #expect(!persistedIDs.contains("\t\n  "))
    }
}
