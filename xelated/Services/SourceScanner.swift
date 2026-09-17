import Foundation
import UniformTypeIdentifiers

nonisolated struct ScanResult: Sendable {
    var items: [MediaItem] = []
    /// Regular files that were readable but weren't photos or videos.
    var skippedCount = 0

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.byteSize } }

    var dateRange: ClosedRange<Date>? {
        let dates = items.map(\.captureDate)
        guard let low = dates.min(), let high = dates.max() else { return nil }
        return low...high
    }
}

nonisolated enum ScanError: LocalizedError {
    case unreadableDirectory(URL)

    var errorDescription: String? {
        switch self {
        case .unreadableDirectory(let url):
            "Couldn't read the folder at \(url.path(percentEncoded: false))."
        }
    }
}

/// Walks a folder and collects every photo and video inside it.
actor SourceScanner {
    private static let resourceKeys: [URLResourceKey] = [
        .isRegularFileKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .contentTypeKey,
    ]

    /// Report progress every this many items rather than per file — a 100k-item scan
    /// shouldn't spend its time hopping to the main actor.
    private static let progressStride = 50

    func scan(
        directory: URL,
        onProgress: @Sendable @escaping (Int) -> Void = { _ in }
    ) async throws -> ScanResult {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Self.resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw ScanError.unreadableDirectory(directory)
        }

        var result = ScanResult()

        for case let url as URL in enumerator {
            try Task.checkCancellation()

            guard let values = try? url.resourceValues(forKeys: Set(Self.resourceKeys)),
                  values.isRegularFile == true
            else { continue }

            guard let contentType = values.contentType,
                  let kind = Self.kind(of: contentType)
            else {
                result.skippedCount += 1
                continue
            }

            let byteSize = Int64(values.fileSize ?? 0)
            let modificationDate = values.contentModificationDate ?? .distantPast
            let captureDate = await CaptureDate.resolve(
                for: url,
                kind: kind,
                modificationDate: modificationDate
            )

            result.items.append(
                MediaItem(
                    sourceURL: url,
                    byteSize: byteSize,
                    modificationDate: modificationDate,
                    captureDate: captureDate,
                    kind: kind
                )
            )

            if result.items.count % Self.progressStride == 0 {
                onProgress(result.items.count)
            }
        }

        onProgress(result.items.count)
        return result
    }

    private static func kind(of type: UTType) -> MediaItem.Kind? {
        if type.conforms(to: .image) { return .photo }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        return nil
    }
}
