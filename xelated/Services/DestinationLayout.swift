import Foundation

/// Works out where an item belongs inside the destination root.
///
/// Layout is `YYYY/YYYY-MM/filename`, keyed on capture date, so the archive is
/// browsable and independent of however the source happened to be organised.
nonisolated enum DestinationLayout {
    /// e.g. `2025/2025-03`.
    static func relativeDirectory(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        let year = parts.year ?? 1970
        let month = parts.month ?? 1
        return String(format: "%04d/%04d-%02d", year, year, month)
    }

    /// Names to try, in order, for an item landing in its month folder.
    ///
    /// Two genuinely different photos can both be called `IMG_4821.HEIC` in the same
    /// month, so later candidates carry a short slice of the content-derived stable key.
    /// The numbered tail covers the (remote) case of two different files whose keys also
    /// share a six-character prefix.
    static func filenameCandidates(for item: MediaItem, limit: Int = 50) -> [String] {
        let base = item.sourceURL.deletingPathExtension().lastPathComponent
        let ext = item.sourceURL.pathExtension

        func assemble(_ stem: String) -> String {
            ext.isEmpty ? stem : "\(stem).\(ext)"
        }

        var names = [assemble(base), assemble("\(base)~\(item.shortKey)")]
        if limit >= 2 {
            names += (2...limit).map { assemble("\(base)~\(item.shortKey)-\($0)") }
        }
        return names
    }
}
