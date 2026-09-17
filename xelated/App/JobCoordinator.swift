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
        case failed(String)

        var isScanning: Bool {
            if case .scanning = self { return true }
            return false
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var scan = ScanResult()
    private(set) var sourceFolder: URL?

    private let scanner = SourceScanner()
    private var scanTask: Task<Void, Never>?

    func selectSource(_ url: URL) {
        sourceFolder = url
        startScan()
    }

    func startScan() {
        guard let sourceFolder else { return }

        scanTask?.cancel()
        scan = ScanResult()
        phase = .scanning(found: 0)

        scanTask = Task {
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

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
    }
}
