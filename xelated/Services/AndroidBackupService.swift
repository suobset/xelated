import Foundation

nonisolated struct BatchPlan: Sendable, Equatable {
    var items: [MediaItem] = []
    var totalBytes: Int64 = 0
    /// What the device reported free at planning time.
    var freeBytes: Int64 = 0
    /// Space deliberately left alone so the photo app has room to work.
    var headroomBytes: Int64 = 0
}

nonisolated struct BatchProgress: Sendable, Equatable {
    var batchNumber = 0
    var total = 0
    var completed = 0
    var pushed = 0
    var failed = 0
    var bytesPushed: Int64 = 0
    var currentFilename: String?

    var fraction: Double { total == 0 ? 0 : Double(completed) / Double(total) }
}

nonisolated struct BatchOutcome: Sendable, Equatable {
    var progress = BatchProgress()
    var failures: [BackupFailure] = []
    var pushedItems: [MediaItem] = []
}

nonisolated enum AndroidBackupError: LocalizedError {
    case noDeviceSelected
    case deviceNotReady(AndroidDevice.State)
    case fileTooLargeForDevice(name: String, size: Int64, usable: Int64)

    var errorDescription: String? {
        switch self {
        case .noDeviceSelected:
            "No Android device selected."
        case .deviceNotReady(let state):
            state.explanation ?? "The phone isn't ready."
        case .fileTooLargeForDevice(let name, let size, let usable):
            "\(name) is \(size.formatted(.byteCount(style: .file))) but only "
                + "\(usable.formatted(.byteCount(style: .file))) is usable on the phone. "
                + "Free up space and try again."
        }
    }
}

/// Moves photos onto an Android phone in batches sized to the space actually available.
///
/// The phone is a staging post: a batch is pushed, the photo app uploads it to the
/// cloud, the batch is cleared off, and the next one goes over. Whether the upload has
/// finished is the one thing the Mac can't determine, so that step is gated on the
/// person confirming it.
actor AndroidBackupService {
    /// Never fill the phone right up. A photo backup app needs working room for
    /// thumbnails, caches and its upload queue, and a wedged phone is far more annoying
    /// than a slightly smaller batch.
    static let minimumHeadroom: Int64 = 2 << 30  // 2 GiB
    static let headroomFraction = 0.10

    static let defaultBatchCap: Int64 = 8 << 30  // 8 GiB

    private let adb: ADBClient
    private let ledger: BackupLedger

    init(adb: ADBClient, ledger: BackupLedger) {
        self.adb = adb
        self.ledger = ledger
    }

    // MARK: - Planning

    /// Choose the next batch based on what's actually free on the phone.
    ///
    /// Greedy: walks the outstanding items in order and takes everything that still
    /// fits, so one oversized video doesn't stall the smaller files queued behind it.
    /// A file bigger than the batch cap is therefore skipped while smaller ones flow
    /// past it, and ends up travelling alone once it's all that's left — big files
    /// drift to the end of the run rather than blocking it.
    func planNextBatch(
        from outstanding: [MediaItem],
        serial: String,
        cap: Int64 = AndroidBackupService.defaultBatchCap
    ) async throws -> BatchPlan? {
        guard !outstanding.isEmpty else { return nil }
        let free = try await adb.freeBytes(serial: serial)
        return try Self.makePlan(from: outstanding, freeBytes: free, cap: cap)
    }

    /// The sizing decision on its own, with no device involved, so it can be exercised
    /// without hardware attached.
    static func makePlan(
        from outstanding: [MediaItem],
        freeBytes free: Int64,
        cap: Int64
    ) throws -> BatchPlan? {
        guard !outstanding.isEmpty else { return nil }

        let headroom = max(Self.minimumHeadroom, Int64(Double(free) * Self.headroomFraction))
        let usable = max(0, free - headroom)
        let budget = min(cap, usable)

        var plan = BatchPlan(freeBytes: free, headroomBytes: headroom)
        for item in outstanding where plan.totalBytes + item.byteSize <= budget {
            plan.items.append(item)
            plan.totalBytes += item.byteSize
        }

        // Nothing fit. Either a single file is bigger than the budget but still fits in
        // the usable space (send it alone), or the phone genuinely hasn't room for it.
        if plan.items.isEmpty, let first = outstanding.first {
            guard first.byteSize <= usable else {
                throw AndroidBackupError.fileTooLargeForDevice(
                    name: first.filename,
                    size: first.byteSize,
                    usable: usable
                )
            }
            plan.items = [first]
            plan.totalBytes = first.byteSize
        }

        return plan
    }

    // MARK: - Pushing

    func push(
        _ plan: BatchPlan,
        serial: String,
        batchNumber: Int,
        onProgress: @Sendable @escaping (BatchProgress) -> Void
    ) async throws -> BatchOutcome {
        try await adb.makeRemoteDirectory(serial: serial)

        var outcome = BatchOutcome()
        outcome.progress.batchNumber = batchNumber
        outcome.progress.total = plan.items.count

        // Two files in one batch can share a name; the staging folder is flat, so keep
        // track of what's been used and fall back to the same ~shortkey scheme the
        // drive layout uses.
        var usedNames: Set<String> = []

        for item in plan.items {
            try Task.checkCancellation()
            outcome.progress.currentFilename = item.filename

            let name = Self.uniqueName(for: item, avoiding: usedNames)
            usedNames.insert(name)
            let remotePath = "\(ADBClient.remoteDirectory)/\(name)"

            do {
                try await adb.push(
                    serial: serial, localURL: item.sourceURL, remotePath: remotePath,
                    byteSize: item.byteSize
                )

                // adb push exits 0 on a partial transfer in some failure modes, so
                // confirm the byte count landed rather than trusting the exit status.
                let remoteSize = try await adb.remoteFileSize(serial: serial, path: remotePath)
                guard remoteSize == item.byteSize else {
                    try? await adb.removeRemoteFiles(serial: serial, paths: [remotePath])
                    throw DriveBackupError.sizeMismatch(item.filename)
                }

                outcome.progress.pushed += 1
                outcome.progress.bytesPushed += item.byteSize
                outcome.pushedItems.append(item)
                try await ledger.record(
                    item,
                    destination: .androidDevice,
                    state: .pushed(devicePath: remotePath, at: .now)
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                outcome.progress.failed += 1
                outcome.failures.append(
                    BackupFailure(filename: item.filename, reason: error.localizedDescription)
                )
            }

            outcome.progress.completed += 1
            onProgress(outcome.progress)
        }

        // Fire-and-forget: recent Android indexes anything written through the FUSE
        // layer automatically, so this is only a nudge. Not awaiting it means a slow or
        // wedged scan can never delay showing the handoff screen.
        let adb = self.adb
        Task { try? await adb.requestMediaScan(serial: serial) }

        try await ledger.sync()
        return outcome
    }

    private static func uniqueName(for item: MediaItem, avoiding used: Set<String>) -> String {
        for candidate in DestinationLayout.filenameCandidates(for: item)
        where !used.contains(candidate) {
            return candidate
        }
        return "\(item.stableKey).\(item.sourceURL.pathExtension)"
    }

    // MARK: - Handoff

    /// What's still sitting in the staging folder.
    func stagedFiles(serial: String) async throws -> [String] {
        try await adb.listRemoteDirectory(serial: serial)
    }

    /// Delete the staging folder's contents. Only ever touches Xelated's own folder.
    func clearStagingFolder(serial: String) async throws {
        let names = try await adb.listRemoteDirectory(serial: serial)
        guard !names.isEmpty else { return }
        try await adb.removeRemoteFiles(
            serial: serial,
            paths: names.map { "\(ADBClient.remoteDirectory)/\($0)" }
        )
    }

    /// Record that the person confirmed these reached the cloud.
    func confirmUploaded(_ items: [MediaItem]) async throws {
        for item in items {
            try await ledger.record(
                item,
                destination: .androidDevice,
                state: .confirmedUploaded(at: .now)
            )
        }
        try await ledger.sync()
    }

    /// Advisory only — see `ADBClient.backupNotificationHint`.
    func backupHint(serial: String) async -> ADBClient.BackupHint {
        await adb.backupNotificationHint(serial: serial)
    }

    func outstanding(from items: [MediaItem]) async -> [MediaItem] {
        await ledger.outstanding(from: items, for: .androidDevice)
    }
}
