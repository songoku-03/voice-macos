import Foundation
@testable import Engine

/// In-memory `FileStoring` mock for deterministic tests — no real disk I/O.
/// Configurable error properties exercise failure paths (skill: swift-protocol-di-testing).
/// NOTE: Not thread-safe. Use only in single-threaded test contexts.
final class InMemoryFileStore: FileStoring, @unchecked Sendable {
    var files: [URL: Data] = [:]
    var readError: Error?
    var writeError: Error?
    private(set) var writeCount = 0

    init(seed: [URL: Data] = [:]) {
        self.files = seed
    }

    func read(from url: URL) throws -> Data {
        if let readError { throw readError }
        guard let data = files[url] else { throw CocoaError(.fileReadNoSuchFile) }
        return data
    }

    func write(_ data: Data, to url: URL) throws {
        if let writeError { throw writeError }
        files[url] = data
        writeCount += 1
    }

    func fileExists(at url: URL) -> Bool {
        files[url] != nil
    }
}
