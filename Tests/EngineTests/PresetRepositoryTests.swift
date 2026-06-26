import Testing
import Foundation
@testable import Engine

@Suite("PresetRepository (actor persistence)")
struct PresetRepositoryTests {
    let url = URL(fileURLWithPath: "/virtual/presets.json")

    @Test("save then load round-trips presets")
    func roundTrip() async throws {
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

    @Test("load returns empty when file is missing")
    func loadMissing() async {
        let repo = PresetRepository(fileStore: InMemoryFileStore(), fileURL: url)
        let loaded = await repo.load()
        #expect(loaded.isEmpty)
    }

    @Test("load returns empty on corrupt data instead of throwing")
    func loadCorrupt() async {
        let store = InMemoryFileStore(seed: [url: Data("not json".utf8)])
        let repo = PresetRepository(fileStore: store, fileURL: url)
        let loaded = await repo.load()
        #expect(loaded.isEmpty)
    }

    @Test("save propagates write errors")
    func saveError() async {
        let store = InMemoryFileStore()
        store.writeError = CocoaError(.fileWriteNoPermission)
        let repo = PresetRepository(fileStore: store, fileURL: url)

        await #expect(throws: (any Error).self) {
            try await repo.save([Preset(name: "Flat", isDefault: true, appSettings: [:])])
        }
    }

    @Test("loadSynchronously decodes without entering the actor")
    func syncLoad() throws {
        let store = InMemoryFileStore()
        let presets = [Preset(name: "Flat", isDefault: true, appSettings: [:])]
        store.files[url] = try JSONEncoder().encode(presets)

        let loaded = PresetRepository.loadSynchronously(fileStore: store, fileURL: url)
        #expect(loaded == presets)
    }
}
