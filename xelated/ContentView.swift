import SwiftUI

struct ContentView: View {
    @State private var coordinator = JobCoordinator()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                if let setupError = coordinator.setupError {
                    Label(setupError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                locationRow(
                    title: "Source",
                    path: coordinator.sourceFolder?.path(percentEncoded: false),
                    placeholder: "No folder chosen",
                    action: coordinator.chooseSource
                )
                locationRow(
                    title: "External Drive",
                    path: coordinator.driveDestination?.path(percentEncoded: false),
                    placeholder: "No destination chosen",
                    warning: coordinator.destinationIsMissing ? "Not connected" : nil,
                    action: coordinator.chooseDriveDestination
                )
                phoneRow
            }
            .padding()

            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 540)
        .task { coordinator.refreshDevices() }
    }

    // MARK: - Header rows

    private func locationRow(
        title: String,
        path: String?,
        placeholder: String,
        warning: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    if let warning {
                        Text(warning).font(.caption).foregroundStyle(.orange)
                    }
                }
                Text(path ?? placeholder)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            Button(path == nil ? "Choose…" : "Change…", action: action)
                .disabled(coordinator.phase.isBusy)
        }
    }

    private var phoneRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Android Phone").font(.headline)
                if let problem = coordinator.adbProblem {
                    Text(problem)
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                } else if coordinator.devices.isEmpty {
                    Text("No device connected")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("", selection: $coordinator.selectedDeviceSerial) {
                        ForEach(coordinator.devices) { device in
                            Text(device.displayName).tag(Optional(device.serial))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()

                    if let explanation = coordinator.selectedDevice?.state.explanation {
                        Text(explanation).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            batchCapField
            Button("Refresh") { coordinator.refreshDevices() }
                .disabled(coordinator.phase.isBusy)
        }
    }

    private var batchCapField: some View {
        HStack(spacing: 4) {
            Text("Batch cap")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField(
                "",
                value: $coordinator.batchCapGiB,
                format: .number.precision(.fractionLength(0...1))
            )
            .frame(width: 44)
            .multilineTextAlignment(.trailing)
            Text("GB").font(.subheadline).foregroundStyle(.secondary)
        }
        .disabled(coordinator.phase.isBusy)
        .help("Largest batch to put on the phone at once. Free space on the phone can lower this, but never raise it.")
    }

    private var footer: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if coordinator.androidAlreadyUploadedCount > 0 && !coordinator.phase.isBusy {
                alreadyUploadedNote
            }
            HStack {
                if coordinator.phase.isBusy {
                    Button("Cancel", role: .cancel) { coordinator.cancel() }
                }
                Spacer()
                Button("Back Up to Phone") { coordinator.startAndroidBackup() }
                    .disabled(!coordinator.canBackUpToPhone)
                Button("Back Up to Drive") { coordinator.startDriveBackup() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!coordinator.canBackUpToDrive)
            }
        }
        .padding()
    }

    private var alreadyUploadedNote: some View {
        HStack {
            Text(
                "\(coordinator.androidAlreadyUploadedCount) of \(coordinator.scan.items.count) "
                + "already sent to a phone"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Button("Upload Again") { coordinator.forceReuploadToPhone() }
                .disabled(!coordinator.canBackUpToPhone)
                .help("Push every file in this scan to the phone again, ignoring what's already been sent.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Main content

    @ViewBuilder
    private var content: some View {
        switch coordinator.phase {
        case .idle:
            placeholder("Choose a folder of photos and videos to get started.")

        case .scanning(let found):
            centred {
                ProgressView()
                Text("Scanning… \(found) found").foregroundStyle(.secondary)
            }

        case .failed(let message):
            placeholder(message)

        case .scanned:
            if coordinator.scan.items.isEmpty {
                placeholder("No photos or videos in that folder.")
            } else {
                itemList
            }

        case .backingUp(let progress):
            centred {
                ProgressView(value: progress.fraction).frame(maxWidth: 320)
                Text("\(progress.completed) of \(progress.total)").monospacedDigit()
                if let filename = progress.currentFilename {
                    Text(filename).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }

        case .pushingBatch(let progress):
            centred {
                ProgressView(value: progress.fraction).frame(maxWidth: 320)
                Text("Batch \(progress.batchNumber) — \(progress.completed) of \(progress.total)")
                    .monospacedDigit()
                if let filename = progress.currentFilename {
                    Text(filename).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }

        case .awaitingHandoff(let handoff):
            HandoffView(
                handoff: handoff,
                deviceName: coordinator.selectedDevice?.displayName ?? "the phone",
                onRefresh: coordinator.refreshHandoffStatus,
                onDecision: coordinator.resolveHandoff
            )

        case .androidFinished(let pushed, let failed):
            VStack(alignment: .leading, spacing: 8) {
                Label("Phone backup finished", systemImage: "checkmark.circle")
                    .font(.headline)
                    .foregroundStyle(failed == 0 ? .green : .orange)
                Text("\(pushed) files went to the phone and were confirmed uploaded.")
                if failed > 0 {
                    Text("\(failed) failed and are still queued for a future run.")
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
            .padding()

        case .finished(let outcome):
            finishedView(outcome)
        }
    }

    private func finishedView(_ outcome: BackupOutcome) -> some View {
        let progress = outcome.progress
        return VStack(alignment: .leading, spacing: 12) {
            Label("Backup complete", systemImage: "checkmark.circle")
                .font(.headline)
                .foregroundStyle(progress.failed == 0 ? .green : .orange)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(progress.copied) copied — \(progress.bytesCopied.formatted(.byteCount(style: .file)))")
                if progress.alreadyPresent > 0 {
                    Text("\(progress.alreadyPresent) already on the drive, left untouched")
                        .foregroundStyle(.secondary)
                }
                if progress.failed > 0 {
                    Text("\(progress.failed) failed").foregroundStyle(.orange)
                }
            }

            if !outcome.failures.isEmpty {
                List(outcome.failures) { failure in
                    VStack(alignment: .leading) {
                        Text(failure.filename)
                        Text(failure.reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
        .padding()
    }

    private var itemList: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
                .padding(.horizontal)
                .padding(.vertical, 8)
            Divider()
            List(coordinator.scan.items) { item in
                HStack {
                    Image(systemName: item.kind == .video ? "film" : "photo")
                        .foregroundStyle(.secondary)
                    Text(item.filename).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(item.captureDate, format: .dateTime.year().month().day())
                        .foregroundStyle(.secondary)
                    Text(item.byteSize.formatted(.byteCount(style: .file)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 80, alignment: .trailing)
                }
            }
        }
    }

    private var summary: some View {
        let scan = coordinator.scan
        let photos = scan.items.count { $0.kind == .photo }
        let videos = scan.items.count - photos

        return VStack(alignment: .leading, spacing: 2) {
            Text("\(photos) photos, \(videos) videos — \(scan.totalBytes.formatted(.byteCount(style: .file)))")
                .font(.headline)
            if let range = scan.dateRange {
                Text(range.lowerBound..<range.upperBound, format: .interval.year().month().day())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if scan.skippedCount > 0 {
                Text("\(scan.skippedCount) non-media files skipped")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func centred<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 8, content: content)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func placeholder(_ message: String) -> some View {
        Text(message)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ContentView()
}
