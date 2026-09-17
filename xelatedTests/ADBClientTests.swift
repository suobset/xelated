import Foundation
import Testing
@testable import xelated

/// `adb` output parsing and the `Process` plumbing underneath it.
///
/// The plumbing tests point `ADBClient` at `/bin/sh` instead of `adb`, so the parts most
/// likely to hang or deadlock in production can be exercised with no phone attached.
@Suite("ADB client")
struct ADBClientTests {
    private var shell: ADBClient { ADBClient(executableURL: URL(filePath: "/bin/sh")) }

    // MARK: - Parsing

    @Test("A ready device is parsed with its model")
    func parsesReadyDevice() throws {
        let line = "39061FDJH00KDT  device product:walleye model:Pixel_2 device:walleye transport_id:1"
        let device = try #require(ADBClient.parseDeviceLine(line))

        #expect(device.serial == "39061FDJH00KDT")
        #expect(device.state == .ready)
        #expect(device.model == "Pixel_2")
        #expect(device.state.isUsable)
        #expect(device.displayName == "Pixel 2")
    }

    @Test("Unusable device states are recognised", arguments: [
        ("1a2b3c4d  unauthorized usb:341835776X", AndroidDevice.State.unauthorized),
        ("9f8e7d6c  offline", AndroidDevice.State.offline),
        ("5e4d3c2b  weirdstate", AndroidDevice.State.unknown),
    ])
    func parsesUnusableStates(line: String, expected: AndroidDevice.State) throws {
        let device = try #require(ADBClient.parseDeviceLine(line))

        #expect(device.state == expected)
        #expect(device.state.isUsable == false)
        #expect(device.state.explanation != nil, "the UI needs something actionable to show")
    }

    @Test("Noise lines are ignored", arguments: ["", "   ", "onlyoneword"])
    func ignoresNonDeviceLines(line: String) {
        #expect(ADBClient.parseDeviceLine(line) == nil)
    }

    @Test("A device with no model still parses")
    func parsesDeviceWithoutModel() throws {
        let device = try #require(ADBClient.parseDeviceLine("abc123  device"))

        #expect(device.model == nil)
        #expect(device.displayName == "abc123", "the serial stands in for a missing model")
    }

    // MARK: - Process plumbing

    @Test("Large output on both streams at once doesn't deadlock")
    func drainsBothPipesConcurrently() async throws {
        // Reading one pipe to EOF before starting the other hangs as soon as output
        // exceeds the 64 KiB pipe buffer — which `adb push` comfortably does. If this
        // test times out rather than fails, that regression is back.
        let script = """
            awk 'BEGIN{for(i=0;i<10000;i++) print "stdout padding line"}'
            awk 'BEGIN{for(i=0;i<10000;i++) print "stderr padding line"}' 1>&2
            """
        let result = try await shell.run(["-c", script], timeout: .seconds(60))

        #expect(result.status == 0)
        #expect(result.stdout.utf8.count > 65_536)
        #expect(result.stderr.utf8.count > 65_536)
    }

    @Test("A non-zero exit is raised rather than swallowed")
    func nonZeroExitThrows() async throws {
        let result = try await shell.run(["-c", "echo nope 1>&2; exit 7"], timeout: .seconds(10))

        #expect(result.status == 7)
        #expect(throws: ADBError.self) { try result.throwIfFailed(command: "sh") }
    }

    @Test("A hung command is killed by its timeout")
    func timeoutTerminatesHungCommand() async throws {
        // A half-connected phone can leave adb hanging indefinitely; without this the
        // whole backup would wedge with no way out.
        let elapsed = try await ContinuousClock().measure {
            _ = try await shell.run(["-c", "sleep 30"], timeout: .seconds(2))
        }
        #expect(elapsed < .seconds(10))
    }

    @Test("Stdout is captured verbatim")
    func capturesStdout() async throws {
        let result = try await shell.run(["-c", "printf 'hello'"], timeout: .seconds(10))
        #expect(result.stdout == "hello")
    }

    @Test("A missing adb binary is reported clearly")
    func missingBinaryIsReported() async {
        let missing = ADBClient(executableURL: URL(filePath: "/nonexistent/adb"))

        await #expect(throws: ADBError.self) { try await missing.checkAvailable() }
        await #expect(throws: ADBError.self) { _ = try await missing.devices() }
    }

    @Test("The staging folder lives under DCIM")
    func stagingFolderIsUnderDCIM() {
        // Photo apps only offer to back up folders they recognise as camera folders,
        // and DCIM subfolders are what they look for.
        #expect(ADBClient.remoteDirectory.hasPrefix("/sdcard/DCIM/"))
    }
}
