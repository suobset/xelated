import Testing
@testable import xelated

/// The staging folder can be a real folder the phone writes into (Screenshots, to
/// satisfy Google Photos' limited "back up other device folders" picker), so anything
/// touching what's "on the device" has to distinguish Xelated's own files from
/// whatever else is already sitting there. These tests pin that boundary down.
@Suite("Android staging safety")
struct AndroidBackupServiceTests {
    @Test("Files that aren't ours are never included")
    func excludesFilesWeDidNotPush() {
        let ours = ["/sdcard/Pictures/Screenshots/IMG_0006.HEIC"]
        let present = [
            "IMG_0006.HEIC",
            "Screenshot_20260919-181203.png",  // a real screenshot, not pushed by us
        ]

        let result = AndroidBackupService.filesStillPresent(ours: ours, present: present)
        #expect(result == ["IMG_0006.HEIC"])
    }

    @Test("A file we pushed but that's since been removed doesn't appear")
    func excludesFilesNoLongerPresent() {
        // Covers "Continue (Already Cleared)": the person deleted our files themselves,
        // so this should read as empty even though the ledger still has a pending entry.
        let ours = ["/sdcard/Pictures/Screenshots/IMG_0006.HEIC"]
        let present = ["Screenshot_20260919-181203.png"]

        #expect(AndroidBackupService.filesStillPresent(ours: ours, present: present).isEmpty)
    }

    @Test("Comparison is by filename, not full remote path")
    func comparesByFilename() {
        let ours = ["/sdcard/Pictures/Screenshots/IMG_0006.HEIC"]
        let present = ["IMG_0006.HEIC"]

        #expect(AndroidBackupService.filesStillPresent(ours: ours, present: present) == ["IMG_0006.HEIC"])
    }

    @Test("Nothing pushed means nothing reported, regardless of what's present")
    func emptyOursYieldsEmptyResult() {
        let present = ["Screenshot_20260919-181203.png", "Screenshot_20260918-090000.png"]
        #expect(AndroidBackupService.filesStillPresent(ours: [], present: present).isEmpty)
    }
}
