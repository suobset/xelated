import Foundation

nonisolated struct BackupProgress: Sendable, Equatable {
    var total = 0
    var completed = 0
    var copied = 0
    /// Already sitting at the destination, so left alone.
    var alreadyPresent = 0
    var failed = 0
    var bytesCopied: Int64 = 0
    var currentFilename: String?

    var fraction: Double {
        total == 0 ? 0 : Double(completed) / Double(total)
    }
}

nonisolated struct BackupFailure: Sendable, Equatable, Identifiable {
    let filename: String
    let reason: String
    var id: String { filename + reason }
}

nonisolated struct BackupOutcome: Sendable, Equatable {
    var progress = BackupProgress()
    var failures: [BackupFailure] = []
}

nonisolated enum DriveBackupError: LocalizedError {
    case sizeMismatch(String)
    case noAvailableName(String)
    case destinationNotWritable(URL)

    var errorDescription: String? {
        switch self {
        case .sizeMismatch(let name):
            "\(name) didn't copy completely."
        case .noAvailableName(let name):
            "Couldn't find a free filename for \(name)."
        case .destinationNotWritable(let url):
            "Can't write to \(url.path(percentEncoded: false))."
        }
    }
}

/// Copies items into the destination root, organised by capture date.
///
/// Additive only. Nothing in the destination is ever deleted or overwritten, so it's
/// safe to point this at a drive that already holds photos, and safe to pick the same
/// folder run after run — anything already there is adopted rather than duplicated.
actor DriveBackupService {
    private enum Placement {
        case copied(relativePath: String)
        case alreadyPresent(relativePath: String)
    }

    private let ledger: BackupLedger

    init(ledger: BackupLedger) {
        self.ledger = ledger
    }

    func backUp(
        items: [MediaItem],
        to root: URL,
        onProgress: @Sendable @escaping (BackupProgress) -> Void
    ) async throws -> BackupOutcome {
        guard FileManager.default.isWritableFile(atPath: root.path) else {
            throw DriveBackupError.destinationNotWritable(root)
        }

        var outcome = BackupOutcome()
        outcome.progress.total = items.count

        for item in items {
            try Task.checkCancellation()
            outcome.progress.currentFilename = item.filename

            do {
                switch try place(item, under: root) {
                case .copied(let relativePath):
                    outcome.progress.copied += 1
                    outcome.progress.bytesCopied += item.byteSize
                    try await ledger.record(
                        item,
                        destination: .drive,
                        state: .copied(relativePath: relativePath, at: .now)
                    )
                case .alreadyPresent(let relativePath):
                    outcome.progress.alreadyPresent += 1
                    try await ledger.record(
                        item,
                        destination: .drive,
                        state: .copied(relativePath: relativePath, at: .now)
                    )
                }
            } catch {
                outcome.progress.failed += 1
                let reason = error.localizedDescription
                outcome.failures.append(BackupFailure(filename: item.filename, reason: reason))
                try? await ledger.record(
                    item,
                    destination: .drive,
                    state: .failed(reason: reason, at: .now)
                )
            }

            outcome.progress.completed += 1
            onProgress(outcome.progress)
        }

        try await ledger.sync()
        return outcome
    }

    /// Find this item a home under `root` without disturbing anything already there.
    ///
    /// Note this consults the filesystem rather than trusting the ledger. The ledger can
    /// be empty while the drive is full — a fresh install, a new Mac, or a folder filled
    /// in by some other tool — and in that situation trusting the ledger alone would
    /// copy everything a second time under `~key` names, right next to the originals.
    private func place(_ item: MediaItem, under root: URL) throws -> Placement {
        let directory = DestinationLayout.relativeDirectory(for: item.captureDate)
        let directoryURL = root.appending(path: directory)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        for candidate in DestinationLayout.filenameCandidates(for: item) {
            let destination = directoryURL.appending(path: candidate)
            let relativePath = "\(directory)/\(candidate)"

            guard let existingSize = fileSize(of: destination) else {
                // Nothing in the way, so this slot is ours.
                try FileManager.default.copyItem(at: item.sourceURL, to: destination)
                guard fileSize(of: destination) == item.byteSize else {
                    throw DriveBackupError.sizeMismatch(item.filename)
                }
                return .copied(relativePath: relativePath)
            }

            // Matching byte count at the exact path this item would have been given is
            // taken as "already backed up". Size alone is a deliberately forgiving test:
            // requiring mtime to match too would spawn a duplicate every time a file
            // arrived by some route that didn't preserve timestamps. The strict SHA-256
            // check happens where it actually matters — before deleting a source file.
            if existingSize == item.byteSize {
                return .alreadyPresent(relativePath: relativePath)
            }

            // Same name, different bytes: a real collision. Try the next candidate.
        }

        throw DriveBackupError.noAvailableName(item.filename)
    }

    private func fileSize(of url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let size = values.fileSize
        else { return nil }
        return Int64(size)
    }
}
