import Testing
import Foundation
@testable import Engine

@Suite struct PresetRepositoryTests {
    let url = URL(fileURLWithPath: "/virtual/presets.json")

    @Test func roundTrip() async throws {
        let store = InMemoryFileStore()
        let repo = PresetRepository(fileStore: store, fileURL: url)

        let presets = [
            Preset(name: "Flat", isDefault: true, appSettings: [:]),
            Preset(name: "Bass", isDefault: false, appSettings: ["com.spotify.client": .flat])
        ]
        try await repo.save(presets)
        let loaded = await repo.load()

        #expect(loaded == presets)
    }

    @Test func loadMissing() async {
        let repo = PresetRepository(fileStore: InMemoryFileStore(), fileURL: url)
        let loaded = await repo.load()
        #expect(loaded.isEmpty)
    }

    @Test func loadCorrupt() async {
        let store = InMemoryFileStore(seed: [url: Data("not json".utf8)])
        let repo = PresetRepository(fileStore: store, fileURL: url)
        let loaded = await repo.load()
        #expect(loaded.isEmpty)
    }

    @Test func saveError() async {
        let store = InMemoryFileStore()
        store.writeError = CocoaError(.fileWriteNoPermission)
        let repo = PresetRepository(fileStore: store, fileURL: url)

        do {
            try await repo.save([Preset(name: "Flat", isDefault: true, appSettings: [:])])
            Issue.record("Expected error")
        } catch {
            // Expected
        }
    }

    @Test func syncLoad() throws {
        let store = InMemoryFileStore()
        let presets = [Preset(name: "Flat", isDefault: true, appSettings: [:])]
        store.files[url] = try JSONEncoder().encode(presets)

        let loaded = PresetRepository.loadSynchronously(fileStore: store, fileURL: url)
        #expect(loaded == presets)
    }
}
