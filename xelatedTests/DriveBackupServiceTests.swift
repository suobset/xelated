import Foundation
import Synchronization
import Testing
@testable import xelated

/// The drive is the real archive, and phase 6 deletes sources based on what landed here.
/// These tests pin down the promise that backing up is purely additive.
@Suite("Drive backup")
struct DriveBackupServiceTests {
    let temp = TempDirectory(name: "xelated-drive")

    private var destination: URL { temp.url.appending(path: "dest") }
    private let monthFolder = "dest/2025/2025-03"

    private func makeService() throws -> DriveBackupService {
        DriveBackupService(ledger: try BackupLedger(directory: temp.url.appending(path: "ledger")))
    }

    /// A source file on disk plus its matching `MediaItem`.
    private func source(_ name: String, bytes: Int) throws -> MediaItem {
        let url = try temp.makeFile("src/\(name)", bytes: bytes)
        return makeItem(name: name, at: url, bytes: Int64(bytes))
    }

    @Test("Files are filed by capture date")
    func filesByCaptureDate() async throws {
        let item = try source("a.jpg", bytes: 100)
        try temp.makeDirectory("dest")

        let outcome = try await makeService().backUp(items: [item], to: destination) { _ in }

        #expect(outcome.progress.copied == 1)
        #expect(outcome.progress.failed == 0)
        #expect(temp.exists("\(monthFolder)/a.jpg"))
    }

    @Test("Files already at the destination are adopted, not recopied")
    func adoptsExistingFiles() async throws {
        // The drive may already hold photos from an earlier run or another tool.
        let item = try source("a.jpg", bytes: 100)
        try temp.makeFile("\(monthFolder)/a.jpg", bytes: 100)

        let outcome = try await makeService().backUp(items: [item], to: destination) { _ in }

        #expect(outcome.progress.copied == 0)
        #expect(outcome.progress.alreadyPresent == 1)
    }

    @Test("Backing up to the same folder twice copies nothing the second time")
    func secondRunIsANoOp() async throws {
        let items = [try source("a.jpg", bytes: 100), try source("b.jpg", bytes: 200)]
        try temp.makeDirectory("dest")
        let service = try makeService()

        _ = try await service.backUp(items: items, to: destination) { _ in }
        let second = try await service.backUp(items: items, to: destination) { _ in }

        #expect(second.progress.copied == 0)
        #expect(second.progress.alreadyPresent == 2)
    }

    @Test("A fresh ledger against a populated drive still copies nothing")
    func freshLedgerDoesNotDuplicate() async throws {
        // Reinstall, or a new Mac. Placement has to consult the filesystem, because
        // trusting an empty ledger would recopy the library under ~key names.
        let items = [try source("a.jpg", bytes: 100), try source("b.jpg", bytes: 200)]
        try temp.makeDirectory("dest")

        _ = try await makeService().backUp(items: items, to: destination) { _ in }

        let withNewLedger = DriveBackupService(
            ledger: try BackupLedger(directory: temp.url.appending(path: "ledger-2"))
        )
        let outcome = try await withNewLedger.backUp(items: items, to: destination) { _ in }

        #expect(outcome.progress.copied == 0)
        #expect(outcome.progress.alreadyPresent == 2)
        #expect(try temp.contents(of: monthFolder) == ["a.jpg", "b.jpg"])
    }

    @Test("A different photo with the same name never overwrites")
    func sameNameDifferentBytesKeepsBoth() async throws {
        try temp.makeFile("\(monthFolder)/a.jpg", bytes: 100)
        let clash = try source("a.jpg", bytes: 150)

        let outcome = try await makeService().backUp(items: [clash], to: destination) { _ in }

        #expect(outcome.progress.copied == 1)
        #expect(temp.size(of: "\(monthFolder)/a.jpg") == 100, "the original must be intact")
        #expect(try temp.contents(of: monthFolder).count == 2)
        #expect(try temp.contents(of: monthFolder).contains("a~\(clash.shortKey).jpg"))
    }

    @Test("Unrelated files in the destination are left alone")
    func leavesUnrelatedFilesUntouched() async throws {
        try temp.makeFile("\(monthFolder)/holiday.jpg", bytes: 77)
        try temp.makeFile("dest/README.txt", bytes: 12)
        let item = try source("a.jpg", bytes: 100)

        _ = try await makeService().backUp(items: [item], to: destination) { _ in }

        #expect(temp.exists("\(monthFolder)/holiday.jpg"))
        #expect(temp.exists("dest/README.txt"))
        #expect(temp.size(of: "\(monthFolder)/holiday.jpg") == 77)
    }

    @Test("Source files are never touched")
    func leavesSourcesIntact() async throws {
        let items = [try source("a.jpg", bytes: 100), try source("b.jpg", bytes: 200)]
        try temp.makeDirectory("dest")

        _ = try await makeService().backUp(items: items, to: destination) { _ in }

        #expect(temp.exists("src/a.jpg"))
        #expect(temp.exists("src/b.jpg"))
        #expect(temp.size(of: "src/a.jpg") == 100)
    }

    @Test("Progress is reported for every item")
    func reportsProgress() async throws {
        let items = [try source("a.jpg", bytes: 100), try source("b.jpg", bytes: 200)]
        try temp.makeDirectory("dest")

        let recorded = Mutex<[Int]>([])
        _ = try await makeService().backUp(items: items, to: destination) { progress in
            recorded.withLock { $0.append(progress.completed) }
        }

        #expect(recorded.withLock { $0 } == [1, 2])
    }

    @Test("An unwritable destination fails before copying anything")
    func rejectsUnwritableDestination() async throws {
        let item = try source("a.jpg", bytes: 100)
        let service = try makeService()

        await #expect(throws: DriveBackupError.self) {
            _ = try await service.backUp(
                items: [item], to: URL(filePath: "/System/xelated-nope")
            ) { _ in }
        }
    }

    @Test("A missing source file is recorded as a failure, not a crash")
    func missingSourceIsReportedAsFailure() async throws {
        try temp.makeDirectory("dest")
        let ghost = makeItem(
            name: "ghost.jpg", at: temp.url.appending(path: "src/ghost.jpg"), bytes: 100
        )

        let outcome = try await makeService().backUp(items: [ghost], to: destination) { _ in }

        #expect(outcome.progress.failed == 1)
        #expect(outcome.progress.copied == 0)
        #expect(outcome.failures.count == 1)
    }

    @Test("Items spanning several months are split across folders")
    func splitsAcrossMonths() async throws {
        try temp.makeDirectory("dest")
        let march = try source("march.jpg", bytes: 100)
        let julyURL = try temp.makeFile("src/july.jpg", bytes: 200)
        let july = makeItem(
            name: "july.jpg", at: julyURL, bytes: 200,
            captureDate: Date(timeIntervalSince1970: 1_751_000_000)  // 2025-06/07
        )

        _ = try await makeService().backUp(items: [march, july], to: destination) { _ in }

        #expect(temp.exists("dest/2025/2025-03/march.jpg"))
        #expect(try temp.contents(of: "dest/2025").count == 2)
    }
}
