import CryptoKit
import Foundation
import Testing
@testable import xelated

/// SHA-256 is what stands between a verified copy and deleting an original, so it has to
/// be correct for large files as well as small ones.
@Suite("Hashing")
struct HashingTests {
    let temp = TempDirectory(name: "xelated-hashing")

    @Test("String hashing matches CryptoKit")
    func stringHashMatchesReference() {
        let reference = SHA256.hash(data: Data("hello".utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        #expect(Hashing.sha256(of: "hello") == reference)
    }

    @Test("Digests are 64 lowercase hex characters")
    func digestFormat() {
        let digest = Hashing.sha256(of: "anything")

        #expect(digest.count == 64)
        #expect(digest.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    @Test("File hashing matches hashing the same bytes in memory")
    func fileHashMatchesInMemory() throws {
        let url = try temp.makeFile("small.bin", bytes: 1_024)
        let expected = SHA256.hash(data: try Data(contentsOf: url))
            .map { String(format: "%02x", $0) }
            .joined()

        #expect(try Hashing.sha256(ofFileAt: url) == expected)
    }

    @Test("Chunked reading is correct across the 1 MiB boundary", arguments: [
        0, 1, 1 << 20 - 1, 1 << 20, 1 << 20 + 1, 3 << 20 + 17,
    ])
    func chunkBoundariesAreHandled(bytes: Int) throws {
        // The file reader works in 1 MiB chunks so a big video never lands in memory
        // whole. Off-by-one handling at the boundary is the thing to get wrong.
        let url = try temp.makeFile("chunk-\(bytes).bin", bytes: bytes)
        let expected = SHA256.hash(data: try Data(contentsOf: url))
            .map { String(format: "%02x", $0) }
            .joined()

        #expect(try Hashing.sha256(ofFileAt: url) == expected)
    }

    @Test("Differing contents hash differently")
    func differentContentsDiffer() throws {
        let a = try temp.makeFile("a.bin", bytes: 100)
        let b = try temp.makeFile("b.bin", bytes: 101)

        #expect(try Hashing.sha256(ofFileAt: a) != Hashing.sha256(ofFileAt: b))
    }

    @Test("A missing file throws rather than returning a bogus digest")
    func missingFileThrows() {
        // Returning the empty-input digest here would let a deletion check pass against
        // a file that isn't there.
        #expect(throws: (any Error).self) {
            _ = try Hashing.sha256(ofFileAt: temp.url.appending(path: "nope.bin"))
        }
    }
}
