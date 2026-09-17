import Foundation

/// Durable record of what has been backed up where.
///
/// Stored as a snapshot plus an append-only JSONL journal. Rewriting one big JSON
/// document after every file would be slow at ~100k items and would leave a corruption
/// window on every write; appending a line is cheap, and a torn final line from a crash
/// is simply discarded on replay.
actor BackupLedger {
    /// Compact once the journal gets long enough that replay starts costing real time.
    private static let compactionThreshold = 5_000

    private let directory: URL
    private let snapshotURL: URL
    private let journalURL: URL

    private var index: [LedgerKey: LedgerEntry] = [:]
    private var journal: FileHandle
    private var journalLineCount = 0

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private struct Snapshot: Codable {
        var version = 1
        var entries: [LedgerEntry]
    }

    /// The default location, `~/Library/Application Support/Xelated`.
    static func defaultDirectory() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appending(path: "Xelated")
    }

    init(directory: URL) throws {
        self.directory = directory
        self.snapshotURL = directory.appending(path: "ledger-snapshot.json")
        self.journalURL = directory.appending(path: "ledger-journal.jsonl")

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: journalURL.path) {
            FileManager.default.createFile(atPath: journalURL.path, contents: nil)
        }

        self.journal = try FileHandle(forWritingTo: journalURL)
        try loadSnapshot()
        try replayJournal()
        try journal.seekToEnd()
    }

    // MARK: - Reading

    func state(of stableKey: String, for destination: DestinationKind) -> ItemState {
        index[LedgerKey(stableKey: stableKey, destination: destination)]?.state ?? .pending
    }

    /// True once this item needs no further work for the given destination.
    func isComplete(_ stableKey: String, for destination: DestinationKind) -> Bool {
        state(of: stableKey, for: destination).isTerminal
    }

    /// Items from `items` that still need work for `destination`.
    func outstanding(from items: [MediaItem], for destination: DestinationKind) -> [MediaItem] {
        items.filter { !isComplete($0.stableKey, for: destination) }
    }

    func entries(for destination: DestinationKind) -> [LedgerEntry] {
        index.values.filter { $0.destination == destination }
    }

    /// Items pushed to the Pixel but never confirmed as uploaded — what to re-offer
    /// after the app was quit mid-batch.
    func unconfirmedPushes() -> [LedgerEntry] {
        index.values.filter { entry in
            guard entry.destination == .pixel, case .pushed = entry.state else { return false }
            return true
        }
    }

    // MARK: - Writing

    func record(
        _ item: MediaItem,
        destination: DestinationKind,
        state: ItemState
    ) throws {
        try record(
            LedgerEntry(
                stableKey: item.stableKey,
                destination: destination,
                state: state,
                filename: item.filename,
                byteSize: item.byteSize,
                recordedAt: .now
            )
        )
    }

    func record(_ entry: LedgerEntry) throws {
        var line = try encoder.encode(entry)
        line.append(0x0A)  // newline
        try journal.write(contentsOf: line)

        index[LedgerKey(stableKey: entry.stableKey, destination: entry.destination)] = entry
        journalLineCount += 1

        if journalLineCount >= Self.compactionThreshold {
            try compact()
        }
    }

    /// Flush to disk. Worth calling at the end of a batch so a crash can't lose the
    /// record of work that actually happened.
    func sync() throws {
        try journal.synchronize()
    }

    /// Fold the journal into a fresh snapshot and start the journal over.
    ///
    /// Snapshot first, then truncate: a crash in between just means the journal gets
    /// replayed over a snapshot that already contains it, and replay is idempotent
    /// because entries overwrite by key.
    func compact() throws {
        let snapshot = Snapshot(entries: Array(index.values))
        try encoder.encode(snapshot).write(to: snapshotURL, options: .atomic)

        try journal.truncate(atOffset: 0)
        try journal.synchronize()
        journalLineCount = 0
    }

    // MARK: - Loading

    private func loadSnapshot() throws {
        guard let data = try? Data(contentsOf: snapshotURL), !data.isEmpty else { return }
        let snapshot = try decoder.decode(Snapshot.self, from: data)
        for entry in snapshot.entries {
            index[LedgerKey(stableKey: entry.stableKey, destination: entry.destination)] = entry
        }
    }

    private func replayJournal() throws {
        guard let data = try? Data(contentsOf: journalURL), !data.isEmpty else { return }

        // Anything past the final newline is a half-written record from a crash
        // mid-append. Truncate it rather than just skipping it: leaving the fragment in
        // place would glue the next appended record onto its tail, turning two records
        // into one unparseable line and silently losing the new one.
        let completeLength = data.lastIndex(of: 0x0A)
            .map { data.distance(from: data.startIndex, to: $0) + 1 } ?? 0
        if completeLength < data.count {
            try journal.truncate(atOffset: UInt64(completeLength))
            try journal.synchronize()
        }

        let lines = data.prefix(completeLength).split(separator: 0x0A, omittingEmptySubsequences: true)
        for (offset, line) in lines.enumerated() {
            guard let entry = try? decoder.decode(LedgerEntry.self, from: Data(line)) else {
                // Every line here is newline-terminated, so this is real corruption
                // rather than a torn tail. Skipping beats refusing to open the ledger.
                print("Xelated: skipping unreadable ledger journal line \(offset + 1)")
                continue
            }
            index[LedgerKey(stableKey: entry.stableKey, destination: entry.destination)] = entry
            journalLineCount += 1
        }
    }
}
