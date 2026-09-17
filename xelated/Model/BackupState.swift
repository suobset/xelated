import Foundation

nonisolated enum DestinationKind: String, Codable, Sendable, CaseIterable {
    case drive
    /// Any Android phone acting as an upload mule for a photo service.
    case androidDevice = "android"
}

/// Where a single item stands with respect to one destination.
nonisolated enum ItemState: Codable, Sendable, Equatable {
    case pending
    /// Copied to the external drive, at a path relative to the destination root.
    case copied(relativePath: String, at: Date)
    /// Sitting on the phone, but not yet known to have reached the cloud.
    case pushed(devicePath: String, at: Date)
    /// The person confirmed the photo service finished with this batch.
    ///
    /// User-asserted, not machine-verified — the Mac has no way to see into Google
    /// Photos' upload queue. Treated as authoritative, but recorded as an assertion so
    /// a later audit can re-push if it turns out to have been premature.
    case confirmedUploaded(at: Date)
    case failed(reason: String, at: Date)

    var isTerminal: Bool {
        switch self {
        case .copied, .confirmedUploaded: true
        case .pending, .pushed, .failed: false
        }
    }
}

nonisolated struct LedgerEntry: Codable, Sendable, Equatable {
    let stableKey: String
    let destination: DestinationKind
    let state: ItemState
    /// Kept alongside the key so the ledger stays readable and auditable on its own,
    /// without needing the source folder to still exist.
    let filename: String
    let byteSize: Int64
    let recordedAt: Date
}

nonisolated struct LedgerKey: Hashable, Sendable {
    let stableKey: String
    let destination: DestinationKind
}
