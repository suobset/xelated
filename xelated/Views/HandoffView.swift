import SwiftUI

/// Shown while a batch sits on the phone, waiting for the photo app to upload it.
struct HandoffView: View {
    let handoff: HandoffState
    let deviceName: String
    let onRefresh: () -> Void
    let onDecision: (HandoffDecision) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                instructions
                statusBox
                actions
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Batch \(handoff.batchNumber) is on \(deviceName)")
                .font(.headline)
            Text("\(handoff.pushedCount) files — \(handoff.pushedBytes.formatted(.byteCount(style: .file)))")
                .foregroundStyle(.secondary)
            if handoff.failedCount > 0 {
                Text("\(handoff.failedCount) failed to copy and will be retried later")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
            if handoff.remainingCount > 0 {
                Text("\(handoff.remainingCount) still to go — \(handoff.remainingBytes.formatted(.byteCount(style: .file)))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("This is the last batch.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("On the phone").font(.subheadline).bold()
            Label(
                "Open Google Photos and let it finish backing up this folder.",
                systemImage: "1.circle"
            )
            Label(
                "Wait until it reports the backup is complete.",
                systemImage: "2.circle"
            )
            Label(
                "Then come back here — Xelated can delete the files off the phone for you.",
                systemImage: "3.circle"
            )
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private var statusBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(handoff.hint.summary)
                        .font(.subheadline)
                    Spacer()
                    Button(action: onRefresh) {
                        if handoff.isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Check Again")
                        }
                    }
                    .disabled(handoff.isRefreshing)
                }

                Text(
                    "This only reads the phone's notifications, so treat it as a nudge "
                    + "rather than proof. Google Photos gives no way to confirm an "
                    + "upload finished — only you can be sure."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Divider()

                Text("\(handoff.stagedFiles.count) files still in the staging folder on the phone")
                    .font(.subheadline)
                    .foregroundStyle(handoff.stagedFiles.isEmpty ? .secondary : .primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Clear Phone & Continue") { onDecision(.clearAndContinue) }
                    .keyboardShortcut(.defaultAction)

                Button("Continue (Already Cleared)") {
                    onDecision(.continueWithoutClearing)
                }
                .disabled(!handoff.stagedFiles.isEmpty)

                Spacer()

                Button("Stop", role: .cancel) { onDecision(.stop) }
            }

            Text(
                handoff.stagedFiles.isEmpty
                    ? "The staging folder is empty, so this batch looks cleared."
                    : "Clearing deletes only the \(handoff.stagedFiles.count) files in "
                        + "Xelated's own folder on the phone. Nothing else is touched."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
