import Foundation

/// Thread-safe, file-backed persistence for the live per-app audio settings
/// (`[bundleID: EQPresetData]`) — the EQ curve + bypass state each app currently
/// has, independent of any named preset. Mirrors `PresetRepository`: an actor so
/// all disk I/O runs off the main thread, with `FileStoring` injected for tests.
@available(macOS 14.2, *)
public actor AppSettingsRepository {
    private let fileStore: FileStoring
    private let fileURL: URL

    public init(fileStore: FileStoring = DefaultFileStore(), fileURL: URL) {
        self.fileStore = fileStore
        self.fileURL = fileURL
    }

    /// Encode and persist atomically. Throws on encode/write failure so callers can log.
    public func save(_ settings: [String: EQPresetData]) throws {
        let data = try JSONEncoder().encode(settings)
        try fileStore.write(data, to: fileURL)
    }

    /// Synchronous decode usable before actor isolation is active (during
    /// `AudioEngineManager.init`, so cached settings exist before taps resume).
    /// Returns `[:]` if the file is missing or undecodable — never blocks launch.
    public nonisolated static func loadSynchronously(fileStore: FileStoring, fileURL: URL) -> [String: EQPresetData] {
        guard fileStore.fileExists(at: fileURL),
              let data = try? fileStore.read(from: fileURL),
              let settings = try? JSONDecoder().decode([String: EQPresetData].self, from: data) else {
            return [:]
        }
        return settings
    }

    /// Default settings file under Application Support, next to presets.json.
    public static func defaultFileURL() -> URL {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent("SoundsSource")
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        return directory.appendingPathComponent("app-settings.json")
    }
}
