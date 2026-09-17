import Foundation
import Observation

/// Owns the state of a backup run and drives the services that do the work.
///
/// Main-actor isolated (the project default), so views can read it directly. The
/// services it calls are actors and do their work off the main thread.
@Observable
final class JobCoordinator {
    enum Phase: Equatable {
        case idle
        case scanning(found: Int)
        case scanned
        case backingUp(BackupProgress)
        case finished(BackupOutcome)
        case failed(String)

        var isScanning: Bool {
            if case .scanning = self { return true }
            return false
        }

        var isBackingUp: Bool {
            if case .backingUp = self { return true }
            return false
        }

        var isBusy: Bool { isScanning || isBackingUp }
    }

    private(set) var phase: Phase = .idle
    private(set) var scan = ScanResult()
    private(set) var sourceFolder: URL?
    private(set) var setupError: String?

    /// Remembered between launches — the same drive folder usually gets reused.
    private(set) var driveDestination: URL? {
        didSet {
            UserDefaults.standard.set(
                driveDestination?.path(percentEncoded: false),
                forKey: Self.driveDestinationKey
            )
        }
    }

    private static let driveDestinationKey = "driveDestination"

    private let scanner = SourceScanner()
    private var ledger: BackupLedger?
    private var driveBackup: DriveBackupService?
    private var task: Task<Void, Never>?

    var canBackUp: Bool {
        !scan.items.isEmpty && driveDestination != nil && !phase.isBusy && ledger != nil
    }

    /// True when the remembered destination isn't reachable — usually an unplugged drive.
    var destinationIsMissing: Bool {
        guard let driveDestination else { return false }
        return !FileManager.default.fileExists(atPath: driveDestination.path)
    }

    init() {
        if let path = UserDefaults.standard.string(forKey: Self.driveDestinationKey) {
            driveDestination = URL(filePath: path)
        }
        do {
            let ledger = try BackupLedger(directory: try BackupLedger.defaultDirectory())
            self.ledger = ledger
            self.driveBackup = DriveBackupService(ledger: ledger)
        } catch {
            setupError = "Couldn't open the backup ledger: \(error.localizedDescription)"
        }
    }

    // MARK: - Source

    func chooseSource() {
        guard let url = FolderPicker.choose(
            title: "Choose Source",
            message: "Pick the folder of photos and videos to back up.",
            startingAt: sourceFolder
        ) else { return }

        sourceFolder = url
        startScan()
    }

    func startScan() {
        guard let sourceFolder else { return }

        task?.cancel()
        scan = ScanResult()
        phase = .scanning(found: 0)

        task = Task {
            do {
                let result = try await scanner.scan(directory: sourceFolder) { found in
                    Task { @MainActor in
                        // Ignore late progress from a scan that's already been replaced.
                        if self.phase.isScanning { self.phase = .scanning(found: found) }
                    }
                }
                scan = result
                phase = .scanned
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Destination

    func chooseDriveDestination() {
        guard let url = FolderPicker.choose(
            title: "Choose Backup Destination",
            message: "Pick a folder on the external drive, or make a new one. "
                + "Anything already in it is left alone.",
            startingAt: driveDestination ?? URL(filePath: "/Volumes")
        ) else { return }

        driveDestination = url
    }

    // MARK: - Backup

    func startDriveBackup() {
        guard let driveBackup, let driveDestination, !scan.items.isEmpty else { return }

        task?.cancel()
        phase = .backingUp(BackupProgress(total: scan.items.count))

        let items = scan.items
        task = Task {
            do {
                let outcome = try await driveBackup.backUp(items: items, to: driveDestination) { progress in
                    Task { @MainActor in
                        if self.phase.isBackingUp { self.phase = .backingUp(progress) }
                    }
                }
                phase = .finished(outcome)
            } catch is CancellationError {
                phase = .scanned
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
