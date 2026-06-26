import Foundation
import Observation

@available(macOS 14.2, *)
@Observable
@MainActor
public class PresetStore: @unchecked Sendable {
    public static let shared = PresetStore()

    public private(set) var presets: [Preset] = []

    // Durable, thread-safe backing store. All disk writes run on this actor's
    // executor (off the main thread); `presets` above is the main-actor copy
    // SwiftUI observes. See PresetRepository (ECC swift-actor-persistence skill).
    private let repository: PresetRepository
    private let fileStore: FileStoring
    private let fileURL: URL

    // Chains saves so they hit disk in call order even though each is launched
    // from a synchronous (SwiftUI button) context.
    private var pendingSave: Task<Void, Never>?

    /// Injectable initializer. Production uses `DefaultFileStore` + the app-support
    /// presets file; tests inject an in-memory store + temp URL.
    public init(fileStore: FileStoring = DefaultFileStore(), fileURL: URL = PresetStore.defaultFileURL()) {
        self.fileStore = fileStore
        self.fileURL = fileURL
        self.repository = PresetRepository(fileStore: fileStore, fileURL: fileURL)

        // Synchronous load so the first SwiftUI render already has data.
        self.presets = PresetRepository.loadSynchronously(fileStore: fileStore, fileURL: fileURL)

        // Seed a default Flat preset on first launch.
        if presets.isEmpty {
            presets.append(Preset(name: "Flat", isDefault: true, appSettings: [:]))
            persist()
        }
    }

    public func savePreset(name: String, appSettings: [String: EQPresetData]) {
        // If preset already exists, update it. Otherwise, append new one.
        if let idx = presets.firstIndex(where: { $0.name == name }) {
            var updated = presets[idx]
            updated.appSettings = appSettings
            presets[idx] = updated
        } else {
            let newPreset = Preset(name: name, isDefault: false, appSettings: appSettings)
            presets.append(newPreset)
        }
        persist()
    }

    public func deletePreset(name: String) {
        presets.removeAll { $0.name == name }
        // Ensure we still have at least one default or if we deleted the default, set flat as default
        if !presets.contains(where: { $0.isDefault }) && !presets.isEmpty {
            presets[0].isDefault = true
        }
        persist()
    }

    public func renamePreset(oldName: String, newName: String) {
        guard !newName.isEmpty && oldName != newName else { return }
        if let idx = presets.firstIndex(where: { $0.name == oldName }) {
            presets[idx].name = newName
            persist()
        }
    }

    public func setDefaultPreset(name: String) {
        for idx in 0..<presets.count {
            presets[idx].isDefault = (presets[idx].name == name)
        }
        persist()
    }

    public var defaultPreset: Preset? {
        return presets.first { $0.isDefault }
    }

    /// Await any in-flight disk write. Call before app termination so a fire-and-forget
    /// save can't be lost; tests use it to assert deterministically on persisted state.
    public func flush() async {
        await pendingSave?.value
    }

    /// Persist the current in-memory state via the actor. Writes are chained so a
    /// rapid sequence (e.g. delete then re-add) lands on disk in order.
    private func persist() {
        let snapshot = presets
        let previous = pendingSave
        pendingSave = Task { [repository] in
            await previous?.value
            do {
                try await repository.save(snapshot)
                print("PresetStore: Saved \(snapshot.count) presets to disk.")
            } catch {
                print("PresetStore: Failed to save presets: \(error)")
            }
        }
    }

    /// Default presets file under Application Support, creating the directory if needed.
    public static func defaultFileURL() -> URL {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent("SoundsSource")
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        return directory.appendingPathComponent("presets.json")
    }
}

@available(macOS 14.2, *)
public struct Preset: Codable, Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var isDefault: Bool
    public var appSettings: [String: EQPresetData] // Keyed by bundle ID

    public init(name: String, isDefault: Bool, appSettings: [String: EQPresetData]) {
        self.name = name
        self.isDefault = isDefault
        self.appSettings = appSettings
    }
}
