import Testing
import AVFoundation
import CoreAudio
@testable import Engine
@testable import Core

/// Covers the per-app-eq-state spec: snapshot-on-detach round-trips, bypass
/// toggling without an active node, and app-settings.json persistence.
@Suite(.serialized)
@MainActor
struct EQStateTests {

    private let fileURL = URL(fileURLWithPath: "/test/app-settings.json")

    private func makeManager(store: InMemoryFileStore) -> AudioEngineManager {
        let manager = AudioEngineManager(fileStore: store, appSettingsFileURL: fileURL)
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

    // 4.1 Snapshot-on-detach: stop → re-tap restores bands and bypass.
    @Test func stopTappingSnapshotsEQAndReTapRestoresIt() throws {
        let manager = makeManager(store: InMemoryFileStore())
        let bundleID = "com.example.eqstate"

        manager.startAppTapping(bundleID: bundleID, pid: getpid())
        guard let node = manager.activeNodes[bundleID] else {
            Issue.record("Expected active node after startAppTapping")
            return
        }

        node.eqController.setBand(index: 0, frequency: 32, gain: 5.0, bandwidth: 1.0)
        node.eqController.setBand(index: 9, frequency: 16000, gain: -3.5, bandwidth: 1.0)
        manager.setEQBypass(bundleID: bundleID, bypassed: true)

        manager.stopAppTapping(bundleID: bundleID)
        #expect(manager.activeNodes[bundleID] == nil)
        #expect(manager.getEQBypass(bundleID: bundleID) == true, "Bypass must survive detach")

        manager.startAppTapping(bundleID: bundleID, pid: getpid())
        guard let newNode = manager.activeNodes[bundleID] else {
            Issue.record("Expected active node after re-tap")
            return
        }
        #expect(abs(newNode.eqController.avAudioUnit.bands[0].gain - 5.0) < 0.001)
        #expect(abs(newNode.eqController.avAudioUnit.bands[9].gain - (-3.5)) < 0.001)
        #expect(newNode.eqController.avAudioUnit.bypass == true, "Re-tapped node must stay bypassed")
        #expect(manager.getEQBypass(bundleID: bundleID) == true)

        manager.stopAppTapping(bundleID: bundleID)
    }

    // 4.3 Toggling bypass with no active node records state and applies on next tap.
    @Test func setEQBypassWithoutActiveNodeAppliesOnNextTap() async throws {
        let store = InMemoryFileStore()
        let manager = makeManager(store: store)
        let bundleID = "com.example.untapped"

        #expect(manager.getEQBypass(bundleID: bundleID) == false)
        manager.setEQBypass(bundleID: bundleID, bypassed: true)
        #expect(manager.getEQBypass(bundleID: bundleID) == true)

        // The flag also lands in the persisted settings (flat curve carrier).
        await manager.flushAppSettings()
        let persisted = AppSettingsRepository.loadSynchronously(fileStore: store, fileURL: fileURL)
        #expect(persisted[bundleID]?.bypass == true)

        manager.startAppTapping(bundleID: bundleID, pid: getpid())
        guard let node = manager.activeNodes[bundleID] else {
            Issue.record("Expected active node after startAppTapping")
            return
        }
        #expect(node.eqController.avAudioUnit.bypass == true, "Recorded bypass must apply to the fresh node")

        manager.stopAppTapping(bundleID: bundleID)
    }

    // Restart round-trip: a second manager over the same store restores state.
    @Test func persistedSettingsSurviveManagerRestart() async throws {
        let store = InMemoryFileStore()
        let bundleID = "com.example.restart"

        let first = makeManager(store: store)
        first.startAppTapping(bundleID: bundleID, pid: getpid())
        first.activeNodes[bundleID]?.eqController.setBand(index: 2, frequency: 125, gain: 7.0, bandwidth: 1.0)
        first.setEQBypass(bundleID: bundleID, bypassed: true)
        first.stopAppTapping(bundleID: bundleID)
        await first.flushAppSettings()

        let second = makeManager(store: store)
        #expect(second.getEQBypass(bundleID: bundleID) == true, "Bypass must be seeded from disk at init")
        second.startAppTapping(bundleID: bundleID, pid: getpid())
        guard let node = second.activeNodes[bundleID] else {
            Issue.record("Expected active node after startAppTapping")
            return
        }
        #expect(abs(node.eqController.avAudioUnit.bands[2].gain - 7.0) < 0.001)
        #expect(node.eqController.avAudioUnit.bypass == true)

        second.stopAppTapping(bundleID: bundleID)
    }
}

/// Covers 4.2: AppSettingsRepository round-trip and corrupt-file fallback.
@Suite
struct AppSettingsRepositoryTests {

    private let fileURL = URL(fileURLWithPath: "/test/app-settings.json")

    @Test func saveLoadRoundTrip() async throws {
        let store = InMemoryFileStore()
        let repository = AppSettingsRepository(fileStore: store, fileURL: fileURL)

        var settings = ["com.example.app": EQPresetData.flat]
        settings["com.example.other"] = EQPresetData(
            bands: EQPresetData.flat.bands,
            bypass: true,
            volume: 0.8
        )
        try await repository.save(settings)

        let loaded = AppSettingsRepository.loadSynchronously(fileStore: store, fileURL: fileURL)
        #expect(loaded == settings)
    }

    @Test func missingFileReturnsEmpty() {
        let loaded = AppSettingsRepository.loadSynchronously(fileStore: InMemoryFileStore(), fileURL: fileURL)
        #expect(loaded == [:])
    }

    @Test func corruptFileFallsBackToEmpty() {
        let store = InMemoryFileStore(seed: [fileURL: Data("{not valid json".utf8)])
        let loaded = AppSettingsRepository.loadSynchronously(fileStore: store, fileURL: fileURL)
        #expect(loaded == [:])
    }
}
