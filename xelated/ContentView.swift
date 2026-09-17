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
            }
            .padding()

            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()

            HStack {
                if coordinator.phase.isBusy {
                    Button("Cancel", role: .cancel) { coordinator.cancel() }
                }
                Spacer()
                Button("Back Up to Drive") { coordinator.startDriveBackup() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!coordinator.canBackUp)
            }
            .padding()
        }
        .frame(minWidth: 600, minHeight: 480)
    }

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
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.orange)
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
                ProgressView(value: progress.fraction)
                    .frame(maxWidth: 320)
                Text("\(progress.completed) of \(progress.total)")
                    .monospacedDigit()
                if let filename = progress.currentFilename {
                    Text(filename)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

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
                        Text(failure.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                    Text(item.filename)
                        .lineLimit(1)
                        .truncationMode(.middle)
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
