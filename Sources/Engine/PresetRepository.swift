import Foundation

/// Thread-safe, file-backed persistence layer for `[Preset]`.
///
/// The actor model serializes all disk access — no locks, no data races, enforced
/// by the compiler. File I/O runs off the main thread, so saving presets never
/// blocks the UI. The `@Observable @MainActor` `PresetStore` wraps this actor as
/// its durable backing store while owning the in-memory copy SwiftUI observes.
///
/// Adapted from the ECC `swift-actor-persistence` skill.
@available(macOS 14.2, *)
public actor PresetRepository {
    private let fileStore: FileStoring
    private let fileURL: URL

    public init(fileStore: FileStoring = DefaultFileStore(), fileURL: URL) {
        self.fileStore = fileStore
        self.fileURL = fileURL
    }

    /// Decode the persisted presets. Returns `[]` if the file is missing or unreadable.
    public func load() -> [Preset] {
        Self.loadSynchronously(fileStore: fileStore, fileURL: fileURL)
    }

    /// Encode and persist atomically. Throws on encode/write failure so callers can log.
    public func save(_ presets: [Preset]) throws {
        let data = try JSONEncoder().encode(presets)
        try fileStore.write(data, to: fileURL)
    }

    /// Synchronous decode usable before actor isolation is active (e.g. during the
    /// owning store's `init`, so the first SwiftUI render already has data).
    /// `nonisolated` + only-`Sendable`-parameters keeps it callable from any context.
    public nonisolated static func loadSynchronously(fileStore: FileStoring, fileURL: URL) -> [Preset] {
        guard fileStore.fileExists(at: fileURL),
              let data = try? fileStore.read(from: fileURL),
              let presets = try? JSONDecoder().decode([Preset].self, from: data) else {
            return []
        }
        return presets
    }
}
