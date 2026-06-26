import Foundation

/// Abstraction over file-system access so persistence layers can be unit-tested
/// without touching the real disk. Production code uses `DefaultFileStore`; tests
/// inject an in-memory mock. Kept intentionally small — one external concern only.
///
/// Adapted from the ECC `swift-protocol-di-testing` skill.
public protocol FileStoring: Sendable {
    func read(from url: URL) throws -> Data
    func write(_ data: Data, to url: URL) throws
    func fileExists(at url: URL) -> Bool
}

/// Production implementation backed by `Foundation`'s `Data` / `FileManager`.
/// Writes are atomic so a crash mid-write can't corrupt the file.
public struct DefaultFileStore: FileStoring {
    public init() {}

    public func read(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    public func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    public func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
