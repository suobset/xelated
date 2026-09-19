import Foundation
import Observation

/// State shown while a batch sits on the phone waiting to be uploaded.
nonisolated struct HandoffState: Sendable, Equatable {
    var batchNumber = 0
    var pushedCount = 0
    var pushedBytes: Int64 = 0
    var failedCount = 0
    var remainingCount = 0
    var remainingBytes: Int64 = 0
    var stagedFiles: [String] = []
    var hint: ADBClient.BackupHint = .indeterminate
    var isRefreshing = true
    /// False until the staging folder has actually been checked at least once. Gates
    /// "Continue (Already Cleared)" — an empty `stagedFiles` shouldn't enable it before
    /// that emptiness has been confirmed, it's just the field's default value.
    var hasCheckedStagedFiles = false
}

nonisolated enum HandoffDecision: Sendable, Equatable {
    /// Delete the batch off the phone, then move on.
    case clearAndContinue
    /// The person already cleared it themselves.
    case continueWithoutClearing
    case stop
}

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
        case pushingBatch(BatchProgress)
        case awaitingHandoff(HandoffState)
        case androidFinished(pushed: Int, failed: Int)
        case failed(String)

        var isScanning: Bool {
            if case .scanning = self { return true }
            return false
        }

        var isBusy: Bool {
            switch self {
            case .scanning, .backingUp, .pushingBatch, .awaitingHandoff: true
            case .idle, .scanned, .finished, .androidFinished, .failed: false
            }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var scan = ScanResult()
    private(set) var sourceFolder: URL?
    private(set) var setupError: String?

    private(set) var devices: [AndroidDevice] = []
    var selectedDeviceSerial: String?
    private(set) var adbProblem: String?

    /// How many items in the current scan the ledger already considers done for the
    /// phone destination — shown so "upload again" can be an explicit choice rather
    /// than something the person has to guess is even possible.
    private(set) var androidAlreadyUploadedCount = 0

    /// Remembered between launches — the same drive folder usually gets reused.
    private(set) var driveDestination: URL? {
        didSet {
            UserDefaults.standard.set(
                driveDestination?.path(percentEncoded: false),
                forKey: Self.driveDestinationKey
            )
        }
    }

    /// Upper bound on a single batch, in gibibytes. The phone's free space can lower
    /// this but never raise it.
    var batchCapGiB: Double = 8 {
        didSet { UserDefaults.standard.set(batchCapGiB, forKey: Self.batchCapKey) }
    }

    private static let driveDestinationKey = "driveDestination"
    private static let batchCapKey = "batchCapGiB"

    private let scanner = SourceScanner()
    private let adb = ADBClient()
    private var ledger: BackupLedger?
    private var driveBackup: DriveBackupService?
    private var androidBackup: AndroidBackupService?
    private var task: Task<Void, Never>?
    private var pendingHandoff: CheckedContinuation<HandoffDecision, Never>?

    var selectedDevice: AndroidDevice? {
        devices.first { $0.serial == selectedDeviceSerial }
    }

    var canBackUpToDrive: Bool {
        !scan.items.isEmpty && driveDestination != nil && !phase.isBusy && driveBackup != nil
    }

    var canBackUpToPhone: Bool {
        !scan.items.isEmpty && selectedDevice?.state.isUsable == true && !phase.isBusy
            && androidBackup != nil
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
        if let cap = UserDefaults.standard.object(forKey: Self.batchCapKey) as? Double, cap > 0 {
            batchCapGiB = cap
        }
        do {
            let ledger = try BackupLedger(directory: try BackupLedger.defaultDirectory())
            self.ledger = ledger
            self.driveBackup = DriveBackupService(ledger: ledger)
            self.androidBackup = AndroidBackupService(adb: adb, ledger: ledger)
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
                refreshAndroidUploadStatus()
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

    // MARK: - Drive backup

    func startDriveBackup() {
        guard let driveBackup, let driveDestination, !scan.items.isEmpty else { return }

        task?.cancel()
        phase = .backingUp(BackupProgress(total: scan.items.count))

        let items = scan.items
        task = Task {
            do {
                let outcome = try await driveBackup.backUp(items: items, to: driveDestination) { progress in
                    Task { @MainActor in
                        if case .backingUp = self.phase { self.phase = .backingUp(progress) }
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

    // MARK: - Devices

    func refreshDevices() {
        Task {
            do {
                devices = try await adb.devices()
                adbProblem = nil
                if selectedDeviceSerial == nil || !devices.contains(where: { $0.serial == selectedDeviceSerial }) {
                    selectedDeviceSerial = devices.first { $0.state.isUsable }?.serial
                        ?? devices.first?.serial
                }
            } catch {
                devices = []
                adbProblem = error.localizedDescription
            }
        }
    }

    // MARK: - Phone backup

    func startAndroidBackup() {
        guard let androidBackup, let device = selectedDevice, device.state.isUsable else { return }

        task?.cancel()
        let items = scan.items
        let cap = Int64(batchCapGiB * Double(1 << 30))
        let serial = device.serial

        task = Task {
            var batchNumber = 0
            var totalPushed = 0
            var totalFailed = 0

            do {
                while true {
                    try Task.checkCancellation()

                    let outstanding = await androidBackup.outstanding(from: items)
                    guard !outstanding.isEmpty else { break }
                    guard let plan = try await androidBackup.planNextBatch(
                        from: outstanding, serial: serial, cap: cap
                    ), !plan.items.isEmpty else { break }

                    batchNumber += 1
                    phase = .pushingBatch(
                        BatchProgress(batchNumber: batchNumber, total: plan.items.count)
                    )

                    let outcome = try await androidBackup.push(
                        plan, serial: serial, batchNumber: batchNumber
                    ) { progress in
                        Task { @MainActor in
                            if case .pushingBatch = self.phase { self.phase = .pushingBatch(progress) }
                        }
                    }
                    totalPushed += outcome.progress.pushed
                    totalFailed += outcome.progress.failed

                    // Nothing made it across — pushing the next batch would just fail
                    // the same way, so stop rather than spin.
                    guard outcome.progress.pushed > 0 else {
                        phase = .failed(
                            outcome.failures.first?.reason ?? "Nothing could be copied to the phone."
                        )
                        return
                    }

                    let stillToGo = await androidBackup.outstanding(from: items)
                        .filter { candidate in !outcome.pushedItems.contains(candidate) }

                    // Show the handoff screen the instant the batch finishes pushing —
                    // don't make it wait on the staging-folder listing or the
                    // notification check. Those are diagnostics, not prerequisites for
                    // clicking through, and a slow or wedged phone shouldn't be able to
                    // block the one screen with a Stop button on it.
                    phase = .awaitingHandoff(
                        HandoffState(
                            batchNumber: batchNumber,
                            pushedCount: outcome.progress.pushed,
                            pushedBytes: outcome.progress.bytesPushed,
                            failedCount: outcome.progress.failed,
                            remainingCount: stillToGo.count,
                            remainingBytes: stillToGo.reduce(0) { $0 + $1.byteSize }
                        )
                    )
                    refreshHandoffStatus()

                    let decision = await awaitHandoff()
                    guard decision != .stop else { break }

                    if decision == .clearAndContinue {
                        try await androidBackup.clearStagingFolder(serial: serial)
                    }
                    try await androidBackup.confirmUploaded(outcome.pushedItems)
                }

                phase = .androidFinished(pushed: totalPushed, failed: totalFailed)
                refreshAndroidUploadStatus()
            } catch is CancellationError {
                phase = .scanned
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// How many of the current scan's items the ledger already considers done for the
    /// phone. Refreshed after scanning and after a backup run, not kept live — the
    /// ledger doesn't change outside those moments.
    private func refreshAndroidUploadStatus() {
        guard let androidBackup, !scan.items.isEmpty else {
            androidAlreadyUploadedCount = 0
            return
        }
        let items = scan.items
        Task {
            androidAlreadyUploadedCount = await androidBackup.alreadyUploadedCount(among: items)
        }
    }

    /// Explicit override: forget completion for every item in the current scan and
    /// push them all to the phone again, regardless of what the ledger already says.
    func forceReuploadToPhone() {
        guard let androidBackup, !scan.items.isEmpty else { return }
        let items = scan.items
        Task {
            try? await androidBackup.forceReupload(items)
            androidAlreadyUploadedCount = 0
            startAndroidBackup()
        }
    }

    // MARK: - The handoff gate

    /// Park the backup loop until the person says the batch has reached the cloud.
    ///
    /// A stored continuation rather than a blocking wait, so the actor stays free and
    /// the surrounding task can still be cancelled.
    private func awaitHandoff() async -> HandoffDecision {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: .stop)
                    return
                }
                pendingHandoff = continuation
            }
        } onCancel: {
            Task { @MainActor in self.resolveHandoff(.stop) }
        }
    }

    /// Resume the parked loop. Clearing the stored continuation first matters: the
    /// cancellation path can race a button press, and resuming twice traps.
    func resolveHandoff(_ decision: HandoffDecision) {
        guard let continuation = pendingHandoff else { return }
        pendingHandoff = nil
        continuation.resume(returning: decision)
    }

    /// Re-check the phone while the handoff prompt is up, without resuming the loop.
    ///
    /// Safe to call whether or not a previous check is still in flight: `ADBClient`
    /// calls don't serialize against each other, so an earlier slow check simply gets
    /// its result discarded (via the `phase` guard below) rather than blocking this one.
    func refreshHandoffStatus() {
        guard case .awaitingHandoff(var handoff) = phase,
              let androidBackup, let serial = selectedDeviceSerial
        else { return }

        handoff.isRefreshing = true
        phase = .awaitingHandoff(handoff)

        Task {
            let staged = (try? await androidBackup.stagedFiles(serial: serial)) ?? []
            let hint = await androidBackup.backupHint(serial: serial)

            guard case .awaitingHandoff(var current) = phase else { return }
            current.stagedFiles = staged
            current.hint = hint
            current.isRefreshing = false
            current.hasCheckedStagedFiles = true
            phase = .awaitingHandoff(current)
        }
    }

    func cancel() {
        resolveHandoff(.stop)
        task?.cancel()
        task = nil
    }
}
