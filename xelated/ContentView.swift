import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var coordinator = JobCoordinator()
    @State private var isChoosingSource = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sourceSection
                .padding()
            Divider()
            resultsSection
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 560, minHeight: 440)
        .fileImporter(
            isPresented: $isChoosingSource,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result {
                coordinator.selectSource(url)
            }
        }
    }

    private var sourceSection: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Source")
                    .font(.headline)
                Text(coordinator.sourceFolder?.path(percentEncoded: false) ?? "No folder chosen")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            if coordinator.phase.isScanning {
                Button("Cancel", role: .cancel) { coordinator.cancelScan() }
            }
            Button("Choose Folder…") { isChoosingSource = true }
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        switch coordinator.phase {
        case .idle:
            placeholder("Choose a folder of photos and videos to get started.")

        case .scanning(let found):
            VStack(spacing: 8) {
                ProgressView()
                Text("Scanning… \(found) found")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            placeholder(message)

        case .scanned:
            if coordinator.scan.items.isEmpty {
                placeholder("No photos or videos in that folder.")
            } else {
                itemList
            }
        }
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
