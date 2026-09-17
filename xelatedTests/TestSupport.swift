import Foundation
@testable import xelated

/// A scratch directory that cleans itself up.
///
/// Held as a stored property of a test suite, Swift Testing creates one per test and
/// releases it afterwards, so each test gets an isolated directory for free.
final class TempDirectory {
    let url: URL

    init(name: String = "xelated-tests") {
        url = URL(filePath: NSTemporaryDirectory())
            .appending(path: "\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func makeDirectory(_ relativePath: String) throws -> URL {
        let directory = url.appending(path: relativePath)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Write a file of a given size. Contents are derived from the size so that files of
    /// differing lengths never coincidentally match.
    @discardableResult
    func makeFile(_ relativePath: String, bytes: Int) throws -> URL {
        let fileURL = url.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: UInt8(bytes % 251), count: bytes).write(to: fileURL)
        return fileURL
    }

    func contents(of relativePath: String) throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: url.appending(path: relativePath).path)
            .sorted()
    }

    func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appending(path: relativePath).path)
    }

    func size(of relativePath: String) -> Int? {
        try? Data(contentsOf: url.appending(path: relativePath)).count
    }
}

/// A `MediaItem` with predictable metadata, for tests that don't care about a real file.
func makeItem(
    name: String = "IMG_0001.HEIC",
    at url: URL? = nil,
    bytes: Int64 = 1_000,
    captureDate: Date = Date(timeIntervalSince1970: 1_741_000_000),  // 2025-03
    kind: MediaItem.Kind = .photo
) -> MediaItem {
    MediaItem(
        sourceURL: url ?? URL(filePath: "/tmp/xelated-fake/\(name)"),
        byteSize: bytes,
        modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
        captureDate: captureDate,
        kind: kind
    )
}

let oneGiB: Int64 = 1 << 30
