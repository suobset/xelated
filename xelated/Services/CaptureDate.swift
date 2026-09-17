import AVFoundation
import Foundation
import ImageIO

/// Works out when a photo or video was actually taken.
///
/// The archive is organised by capture date, so this is the one piece of metadata the
/// layout depends on. Each source is tried in turn, weakest last.
nonisolated enum CaptureDate {
    /// EXIF writes dates as `2025:03:12 18:12:04`, with no timezone attached.
    ///
    /// `DateFormatter` parsing is documented thread-safe once configured, so one shared
    /// instance is fine and avoids rebuilding a formatter per file during a scan.
    private static let exifFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    /// Best available capture date. Always returns something, falling back to the
    /// modification date the caller already read off the filesystem.
    static func resolve(
        for url: URL,
        kind: MediaItem.Kind,
        modificationDate: Date
    ) async -> Date {
        switch kind {
        case .photo:
            if let date = exifDate(for: url) { return date }
        case .video:
            if let date = await videoCreationDate(for: url) { return date }
        }

        // No embedded date, so fall back to the filesystem — but neither timestamp is
        // trustworthy on its own. A plain `cp` resets birth time while preserving mtime;
        // an edit or a `touch` bumps mtime while leaving birth time intact. Both are
        // upper bounds on when the shot was actually taken, so take the earlier one.
        guard let created = fileCreationDate(for: url) else { return modificationDate }
        return min(created, modificationDate)
    }

    /// EXIF `DateTimeOriginal`, then `DateTimeDigitized`, then the TIFF date.
    static func exifDate(for url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any]
        else { return nil }

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

        let candidates = [
            exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
            exif?[kCGImagePropertyExifDateTimeDigitized] as? String,
            tiff?[kCGImagePropertyTIFFDateTime] as? String,
        ]

        for case let candidate? in candidates {
            if let date = exifFormatter.date(from: candidate) { return date }
        }
        return nil
    }

    static func videoCreationDate(for url: URL) async -> Date? {
        let asset = AVURLAsset(url: url)
        guard let item = try? await asset.load(.creationDate) else { return nil }
        return try? await item.load(.dateValue)
    }

    static func fileCreationDate(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
    }
}
