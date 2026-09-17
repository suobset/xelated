import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import xelated

/// Capture date decides which `YYYY/YYYY-MM` folder a photo lands in, so getting the
/// precedence order wrong silently misfiles the whole archive.
@Suite("Capture date resolution")
struct CaptureDateTests {
    let temp = TempDirectory(name: "xelated-capturedate")

    /// Write a real JPEG carrying an EXIF `DateTimeOriginal`.
    private func makeJPEG(exifDate: String?, named name: String) throws -> URL {
        let url = temp.url.appending(path: name)

        let context = try #require(
            CGContext(
                data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        let image = try #require(context.makeImage())
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        )

        var properties: [CFString: Any] = [:]
        if let exifDate {
            properties[kCGImagePropertyExifDictionary] =
                [kCGImagePropertyExifDateTimeOriginal: exifDate] as [CFString: Any]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test("EXIF DateTimeOriginal is parsed from its colon-separated format")
    func parsesExifDate() throws {
        let url = try makeJPEG(exifDate: "2019:07:04 09:15:30", named: "exif.jpg")
        let parsed = try #require(CaptureDate.exifDate(for: url))

        // EXIF carries no timezone, so it's interpreted as local time.
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: parsed
        )
        #expect(components.year == 2019)
        #expect(components.month == 7)
        #expect(components.day == 4)
        #expect(components.hour == 9)
        #expect(components.minute == 15)
        #expect(components.second == 30)
    }

    @Test("EXIF wins over the filesystem for photos")
    func exifBeatsFilesystem() async throws {
        let url = try makeJPEG(exifDate: "2019:07:04 09:15:30", named: "priority.jpg")
        let mtime = Date(timeIntervalSince1970: 0)
        let resolved = await CaptureDate.resolve(for: url, kind: .photo, modificationDate: mtime)

        #expect(resolved != mtime)
        #expect(Calendar.current.component(.year, from: resolved) == 2019)
    }

    @Test("A photo with no EXIF still resolves rather than failing")
    func fallsBackWhenNoExif() async throws {
        let url = try makeJPEG(exifDate: nil, named: "no-exif.jpg")
        #expect(CaptureDate.exifDate(for: url) == nil)

        let mtime = Date(timeIntervalSince1970: 1_000_000_000)
        let resolved = await CaptureDate.resolve(for: url, kind: .photo, modificationDate: mtime)
        #expect(resolved == mtime, "an mtime older than birth time should win")
    }

    @Test("The filesystem fallback takes the earlier of birth time and mtime")
    func fallbackPicksEarlierTimestamp() async throws {
        // A plain `cp` resets birth time but preserves mtime; an edit bumps mtime but
        // leaves birth time alone. Both bound the capture time from above, so the
        // earlier one is the better guess.
        let url = try makeJPEG(exifDate: nil, named: "fallback.jpg")
        let birth = try #require(CaptureDate.fileCreationDate(for: url))

        let olderMtime = Date(timeIntervalSince1970: 1_000_000_000)
        let withOlderMtime = await CaptureDate.resolve(
            for: url, kind: .photo, modificationDate: olderMtime
        )
        #expect(withOlderMtime == olderMtime)

        let newerMtime = Date(timeIntervalSinceNow: 86_400)
        let withNewerMtime = await CaptureDate.resolve(
            for: url, kind: .photo, modificationDate: newerMtime
        )
        #expect(withNewerMtime == birth)
    }

    @Test("Unreadable files resolve to the supplied modification date")
    func garbageFileDoesNotCrash() async throws {
        let url = try temp.makeFile("garbage.jpg", bytes: 3)
        let mtime = Date(timeIntervalSince1970: 1_000_000_000)
        let resolved = await CaptureDate.resolve(for: url, kind: .photo, modificationDate: mtime)
        #expect(resolved == mtime)
    }
}
