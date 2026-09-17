import Foundation
import Testing
@testable import xelated

/// The ledger is the app's memory. If it loses a record the app re-copies; if it invents
/// one the app skips a photo. The crash-recovery cases below are the ones that bite.
@Suite("Backup ledger")
struct BackupLedgerTests {
    let temp = TempDirectory(name: "xelated-ledger")

    private var journalURL: URL { temp.url.appending(path: "ledger-journal.jsonl") }
    private var snapshotURL: URL { temp.url.appending(path: "ledger-snapshot.json") }

    @Test("State survives closing and reopening")
    func persistsAcrossInstances() async throws {
        let item = makeItem(name: "IMG_0001.HEIC", bytes: 100)

        let first = try BackupLedger(directory: temp.url)
        try await first.record(
            item, destination: .drive, state: .copied(relativePath: "2025/2025-03/a.jpg", at: .now)
        )
        try await first.sync()

        let reopened = try BackupLedger(directory: temp.url)
        #expect(await reopened.isComplete(item.stableKey, for: .drive))
    }

    @Test("Destinations are tracked independently")
    func destinationsAreIndependent() async throws {
        let item = makeItem(bytes: 100)
        let ledger = try BackupLedger(directory: temp.url)

        try await ledger.record(
            item, destination: .drive, state: .copied(relativePath: "x", at: .now)
        )

        #expect(await ledger.isComplete(item.stableKey, for: .drive))
        #expect(await ledger.isComplete(item.stableKey, for: .androidDevice) == false)
    }

    @Test("Pushed is not the same as uploaded")
    func pushedIsNotTerminal() async throws {
        // A file sitting on the phone hasn't reached the cloud yet. Treating pushed as
        // done would let the app clear a batch that was never backed up.
        let item = makeItem(bytes: 100)
        let ledger = try BackupLedger(directory: temp.url)

        try await ledger.record(
            item, destination: .androidDevice, state: .pushed(devicePath: "/sdcard/a", at: .now)
        )
        #expect(await ledger.isComplete(item.stableKey, for: .androidDevice) == false)
        #expect(await ledger.unconfirmedPushes().count == 1)

        try await ledger.record(
            item, destination: .androidDevice, state: .confirmedUploaded(at: .now)
        )
        #expect(await ledger.isComplete(item.stableKey, for: .androidDevice))
        #expect(await ledger.unconfirmedPushes().isEmpty)
    }

    @Test("The newest record for a key wins")
    func latestRecordWins() async throws {
        let item = makeItem(bytes: 100)

        let first = try BackupLedger(directory: temp.url)
        try await first.record(
            item, destination: .drive, state: .failed(reason: "disk full", at: .now)
        )
        try await first.record(
            item, destination: .drive, state: .copied(relativePath: "x", at: .now)
        )
        try await first.sync()

        let reopened = try BackupLedger(directory: temp.url)
        #expect(await reopened.isComplete(item.stableKey, for: .drive))
    }

    @Test("outstanding() returns only items still needing work")
    func outstandingFiltersCompleted() async throws {
        let done = makeItem(name: "done.jpg", bytes: 100)
        let todo = makeItem(name: "todo.jpg", bytes: 200)
        let ledger = try BackupLedger(directory: temp.url)

        try await ledger.record(
            done, destination: .drive, state: .copied(relativePath: "x", at: .now)
        )

        let remaining = await ledger.outstanding(from: [done, todo], for: .drive)
        #expect(remaining.map(\.filename) == ["todo.jpg"])
    }

    @Test("A record written after a crash is not swallowed")
    func recoversFromTornFinalLine() async throws {
        // A crash mid-append leaves a fragment with no trailing newline. Merely skipping
        // it isn't enough: the next record gets glued onto the fragment's tail and the
        // pair becomes one unparseable line, silently losing the new record. The
        // fragment has to be truncated.
        let first = makeItem(name: "first.jpg", bytes: 100)
        let second = makeItem(name: "second.jpg", bytes: 200)

        let ledger = try BackupLedger(directory: temp.url)
        try await ledger.record(
            first, destination: .drive, state: .copied(relativePath: "a", at: .now)
        )
        try await ledger.sync()

        let torn = try Data(contentsOf: journalURL)
            + Data(#"{"stableKey":"deadbeef","destina"#.utf8)
        try torn.write(to: journalURL)

        let afterCrash = try BackupLedger(directory: temp.url)
        #expect(await afterCrash.isComplete(first.stableKey, for: .drive))
        try await afterCrash.record(
            second, destination: .drive, state: .copied(relativePath: "b", at: .now)
        )
        try await afterCrash.sync()

        let reopened = try BackupLedger(directory: temp.url)
        #expect(await reopened.entries(for: .drive).count == 2)
        #expect(await reopened.isComplete(second.stableKey, for: .drive))
    }

    @Test("A journal containing nothing but a fragment still opens")
    func recoversFromEntirelyGarbageJournal() async throws {
        try Data(#"{"stableKey":"onlypartial"#.utf8).write(to: journalURL)
        let item = makeItem(bytes: 100)

        let ledger = try BackupLedger(directory: temp.url)
        try await ledger.record(
            item, destination: .drive, state: .copied(relativePath: "a", at: .now)
        )
        try await ledger.sync()

        let reopened = try BackupLedger(directory: temp.url)
        #expect(await reopened.entries(for: .drive).count == 1)
    }

    @Test("Compaction empties the journal without losing state")
    func compactionPreservesState() async throws {
        let drive = makeItem(name: "drive.jpg", bytes: 100)
        let phone = makeItem(name: "phone.jpg", bytes: 200)

        let ledger = try BackupLedger(directory: temp.url)
        try await ledger.record(
            drive, destination: .drive, state: .copied(relativePath: "a", at: .now)
        )
        try await ledger.record(
            phone, destination: .androidDevice, state: .confirmedUploaded(at: .now)
        )
        try await ledger.compact()

        #expect(try Data(contentsOf: journalURL).isEmpty)
        #expect(FileManager.default.fileExists(atPath: snapshotURL.path))

        let reopened = try BackupLedger(directory: temp.url)
        #expect(await reopened.isComplete(drive.stableKey, for: .drive))
        #expect(await reopened.isComplete(phone.stableKey, for: .androidDevice))
    }

    @Test("Records written after compaction survive too")
    func appendsAfterCompactionSurvive() async throws {
        let before = makeItem(name: "before.jpg", bytes: 100)
        let after = makeItem(name: "after.jpg", bytes: 200)

        let ledger = try BackupLedger(directory: temp.url)
        try await ledger.record(
            before, destination: .drive, state: .copied(relativePath: "a", at: .now)
        )
        try await ledger.compact()
        try await ledger.record(
            after, destination: .drive, state: .copied(relativePath: "b", at: .now)
        )
        try await ledger.sync()

        let reopened = try BackupLedger(directory: temp.url)
        #expect(await reopened.entries(for: .drive).count == 2)
    }

    @Test("An unknown key reads as pending rather than throwing")
    func unknownKeyIsPending() async throws {
        let ledger = try BackupLedger(directory: temp.url)
        #expect(await ledger.state(of: "never-seen", for: .drive) == .pending)
    }
}
