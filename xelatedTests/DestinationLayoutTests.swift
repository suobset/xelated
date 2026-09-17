import Foundation
import Testing
@testable import xelated

@Suite("Destination layout")
struct DestinationLayoutTests {
    @Test("Directories are YYYY/YYYY-MM with zero padding")
    func directoryFormat() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))

        func directory(year: Int, month: Int, day: Int) throws -> String {
            let date = try #require(
                calendar.date(from: DateComponents(year: year, month: month, day: day))
            )
            return DestinationLayout.relativeDirectory(for: date, calendar: calendar)
        }

        #expect(try directory(year: 2025, month: 3, day: 12) == "2025/2025-03")
        #expect(try directory(year: 2025, month: 12, day: 31) == "2025/2025-12")
        #expect(try directory(year: 1999, month: 1, day: 1) == "1999/1999-01")
    }

    @Test("The plain filename is preferred")
    func firstCandidateIsTheOriginalName() {
        let item = makeItem(name: "IMG_4821.HEIC")
        #expect(DestinationLayout.filenameCandidates(for: item).first == "IMG_4821.HEIC")
    }

    @Test("Collisions fall back to a content-derived suffix")
    func secondCandidateCarriesShortKey() {
        let item = makeItem(name: "IMG_4821.HEIC")
        let candidates = DestinationLayout.filenameCandidates(for: item)

        #expect(candidates[1] == "IMG_4821~\(item.shortKey).HEIC")
        #expect(candidates[2] == "IMG_4821~\(item.shortKey)-2.HEIC")
    }

    @Test("Candidates are unique and keep the extension")
    func candidatesAreUniqueAndKeepExtension() {
        let candidates = DestinationLayout.filenameCandidates(for: makeItem(name: "IMG_4821.HEIC"))

        #expect(Set(candidates).count == candidates.count)
        #expect(candidates.allSatisfy { $0.hasSuffix(".HEIC") })
    }

    @Test("Files with no extension are handled")
    func handlesMissingExtension() {
        let item = makeItem(name: "IMG_4821")
        let candidates = DestinationLayout.filenameCandidates(for: item)

        #expect(candidates[0] == "IMG_4821")
        #expect(candidates[1] == "IMG_4821~\(item.shortKey)")
        #expect(candidates.allSatisfy { !$0.hasSuffix(".") })
    }

    @Test("Dots inside the name are preserved")
    func handlesDottedNames() {
        // Screen recordings arrive as "Screen Recording 2026-09-16 at 12.54.15.mov";
        // only the final component is the extension.
        let item = makeItem(name: "Screen Recording at 12.54.15.mov")
        let candidates = DestinationLayout.filenameCandidates(for: item)

        // Only the trailing ".mov" counts as the extension; the suffix must be inserted
        // before it, not before the first dot in the name.
        #expect(candidates[0] == "Screen Recording at 12.54.15.mov")
        #expect(candidates[1] == "Screen Recording at 12.54.15~\(item.shortKey).mov")
    }

    @Test("A low limit still produces the two important candidates")
    func respectsLimit() {
        let candidates = DestinationLayout.filenameCandidates(for: makeItem(), limit: 1)
        #expect(candidates.count == 2)
    }
}
