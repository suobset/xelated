import CryptoKit
import Foundation

/// SHA-256 helpers.
///
/// File hashing is streamed in chunks so a multi-gigabyte video never lands in memory
/// all at once.
nonisolated enum Hashing {
    /// Large enough to keep syscall overhead down, small enough that a few concurrent
    /// hashes don't add up to anything meaningful.
    private static let chunkSize = 1 << 20  // 1 MiB

    static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hexadecimal(hasher.finalize())
    }

    static func sha256(of string: String) -> String {
        hexadecimal(SHA256.hash(data: Data(string.utf8)))
    }

    private static func hexadecimal(_ digest: SHA256Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
