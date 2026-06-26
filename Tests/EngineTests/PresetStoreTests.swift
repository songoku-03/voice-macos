import Testing
import Foundation
@testable import Engine

@MainActor
@Suite("PresetStore (observable facade)")
struct PresetStoreTests {
    let url = URL(fileURLWithPath: "/virtual/presets.json")

    /// Fresh store backed by an in-memory file store (no disk, no shared singleton).
    private func makeStore(seed: [Preset]? = nil) throws -> (PresetStore, InMemoryFileStore) {
        let fs = InMemoryFileStore()
        if let seed { fs.files[url] = try JSONEncoder().encode(seed) }
        return (PresetStore(fileStore: fs, fileURL: url), fs)
    }

    @Test("seeds a default Flat preset on first launch")
    func seedsFlat() throws {
        let (store, _) = try makeStore()
        #expect(store.presets.count == 1)
        #expect(store.defaultPreset?.name == "Flat")
    }

    @Test("savePreset appends a new preset")
    func saveAppends() throws {
        let (store, _) = try makeStore(seed: [Preset(name: "Flat", isDefault: true, appSettings: [:])])
        store.savePreset(name: "Bass", appSettings: ["com.app": .flat])
        #expect(store.presets.map(\.name) == ["Flat", "Bass"])
    }

    @Test("savePreset updates an existing preset in place")
    func saveUpdates() throws {
        let (store, _) = try makeStore(seed: [Preset(name: "Flat", isDefault: true, appSettings: [:])])
        store.savePreset(name: "Flat", appSettings: ["com.app": .flat])
        #expect(store.presets.count == 1)
        #expect(store.presets[0].appSettings["com.app"] == .flat)
    }

    @Test("deleting the default reassigns default to the first remaining preset")
    func deleteReassignsDefault() throws {
        let (store, _) = try makeStore(seed: [
            Preset(name: "Flat", isDefault: true, appSettings: [:]),
            Preset(name: "Bass", isDefault: false, appSettings: [:])
        ])
        store.deletePreset(name: "Flat")
        #expect(store.presets.count == 1)
        #expect(store.defaultPreset?.name == "Bass")
    }

    @Test("renamePreset changes the name; no-ops on empty/identical names")
    func rename() throws {
        let (store, _) = try makeStore(seed: [Preset(name: "Flat", isDefault: true, appSettings: [:])])
        store.renamePreset(oldName: "Flat", newName: "Neutral")
        #expect(store.defaultPreset?.name == "Neutral")

        store.renamePreset(oldName: "Neutral", newName: "")
        #expect(store.presets[0].name == "Neutral") // unchanged
    }

    @Test("setDefaultPreset moves the default flag exclusively")
    func setDefault() throws {
        let (store, _) = try makeStore(seed: [
            Preset(name: "Flat", isDefault: true, appSettings: [:]),
            Preset(name: "Bass", isDefault: false, appSettings: [:])
        ])
        store.setDefaultPreset(name: "Bass")
        #expect(store.defaultPreset?.name == "Bass")
        #expect(store.presets.filter(\.isDefault).count == 1)
    }

    @Test("mutations are persisted through the actor to the file store")
    func persistsToDisk() async throws {
        let (store, fs) = try makeStore(seed: [Preset(name: "Flat", isDefault: true, appSettings: [:])])
        store.savePreset(name: "Bass", appSettings: [:])
        await store.flush() // wait for the off-main-thread write

        let persisted = try JSONDecoder().decode([Preset].self, from: #require(fs.files[url]))
        #expect(persisted.map(\.name) == ["Flat", "Bass"])
    }
}
