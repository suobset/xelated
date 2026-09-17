import Foundation

/// A single photo or video discovered at a source location.
nonisolated struct MediaItem: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable, Hashable {
        case photo
        case video
    }

    let sourceURL: URL
    let filename: String
    let byteSize: Int64
    let modificationDate: Date
    let captureDate: Date
    let kind: Kind

    /// Identity for dedupe, both across runs and across source folders.
    ///
    /// Deliberately excludes modification date: importing through Image Capture rewrites
    /// mtime, so folding it in would make the same photo look new on every import.
    /// Filename alone is no good either — iPhone imports hand out the same
    /// `IMG_0001.HEIC` over and over across unrelated imports.
    let stableKey: String

    var id: URL { sourceURL }

    /// A short prefix of the stable key, used to disambiguate destination filenames when
    /// two genuinely different photos share a name within one month folder.
    var shortKey: String { String(stableKey.prefix(6)) }

    init(
        sourceURL: URL,
        byteSize: Int64,
        modificationDate: Date,
        captureDate: Date,
        kind: Kind
    ) {
        let filename = sourceURL.lastPathComponent
        self.sourceURL = sourceURL
        self.filename = filename
        self.byteSize = byteSize
        self.modificationDate = modificationDate
        self.captureDate = captureDate
        self.kind = kind
        self.stableKey = Hashing.sha256(
            of: "\(filename)|\(byteSize)|\(Int(captureDate.timeIntervalSince1970))"
        )
    }
}
