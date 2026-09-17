import Foundation
import Testing
@testable import xelated

/// `stableKey` is the backbone of dedupe — if it drifts between runs, the app re-copies
/// everything; if it collides, the app skips photos it should have backed up.
@Suite("MediaItem identity")
struct MediaItemTests {
    @Test("The same file yields the same key every time")
    func keyIsStable() {
        let a = makeItem(name: "IMG_4821.HEIC", bytes: 2_400_000)
        let b = makeItem(name: "IMG_4821.HEIC", bytes: 2_400_000)
        #expect(a.stableKey == b.stableKey)
    }

    @Test("Modification date is excluded from the key")
    func modificationDateDoesNotAffectKey() {
        // Image Capture rewrites mtime on import. If it fed into the key, every import
        // would look like a brand new set of photos.
        let original = makeItem(name: "IMG_4821.HEIC", bytes: 2_400_000)
        let reimported = MediaItem(
            sourceURL: original.sourceURL,
            byteSize: original.byteSize,
            modificationDate: .now,
            captureDate: original.captureDate,
            kind: original.kind
        )
        #expect(original.stableKey == reimported.stableKey)
    }

    @Test("Source location is excluded from the key")
    func pathDoesNotAffectKey() {
        // The same photo reached from two folders must dedupe against itself.
        let a = makeItem(name: "IMG_4821.HEIC", at: URL(filePath: "/a/IMG_4821.HEIC"), bytes: 100)
        let b = makeItem(name: "IMG_4821.HEIC", at: URL(filePath: "/b/IMG_4821.HEIC"), bytes: 100)
        #expect(a.stableKey == b.stableKey)
    }

    @Test("Different size, name, or capture date yields a different key")
    func differingMetadataChangesKey() {
        let base = makeItem(name: "IMG_4821.HEIC", bytes: 100)
        let biggerFile = makeItem(name: "IMG_4821.HEIC", bytes: 101)
        let differentName = makeItem(name: "IMG_4822.HEIC", bytes: 100)
        let differentDate = makeItem(
            name: "IMG_4821.HEIC", bytes: 100, captureDate: Date(timeIntervalSince1970: 0)
        )

        #expect(base.stableKey != biggerFile.stableKey)
        #expect(base.stableKey != differentName.stableKey)
        #expect(base.stableKey != differentDate.stableKey)
    }

    @Test("Identically named iPhone imports stay distinct")
    func sameNameDifferentPhotosStayDistinct() {
        // iPhone hands out IMG_0001.HEIC over and over across unrelated imports, so the
        // filename alone can never be the identity.
        let keys = Set(
            (1...50).map {
                makeItem(
                    name: "IMG_0001.HEIC",
                    bytes: Int64(1_000 + $0),
                    captureDate: Date(timeIntervalSince1970: Double(1_700_000_000 + $0))
                ).stableKey
            }
        )
        #expect(keys.count == 50)
    }

    @Test("shortKey is a six-character prefix of the full key")
    func shortKeyDerivation() {
        let item = makeItem()
        #expect(item.shortKey.count == 6)
        #expect(item.stableKey.hasPrefix(item.shortKey))
    }
}
