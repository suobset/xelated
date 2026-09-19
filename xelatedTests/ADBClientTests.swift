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

    @Test("The staging folder is the real Screenshots folder")
    func stagingFolderIsScreenshots() {
        // Confirmed against a real Pixel: Google Photos' "Back up other device folders"
        // picker only lists a small set of OS-blessed folders (Camera, Screenshots)
        // unless the app holds "All files access" — and recent Google Photos versions
        // don't even expose a Settings toggle for that permission, so a custom folder
        // (tried first, under Pictures) never appeared no matter what it was named.
        #expect(ADBClient.remoteDirectory == "/sdcard/Pictures/Screenshots")
    }

    // MARK: - Regression: the 2026-09-17 hang

    // `exec` matters here: without it, `sh -c` forks `sleep` as a genuine child rather
    // than replacing itself, and killing the shell's pid — even with SIGKILL — leaves
    // that orphaned child running for its full duration with our pipe's write end still
    // open underneath it (confirmed by hand: `sh -c 'trap "" TERM; sleep N'`,
    // `kill -9`'d, leaves `sleep` alive and the pipe unclosed). `exec` replaces the
    // shell in place, so there's exactly one process — matching a real `adb` client,
    // which is confirmed to never fork local children of its own.
    private static let stubbornProcessScript = "trap '' TERM; exec sleep 30"

    @Test("A process that ignores SIGTERM is still killed")
    func processIgnoringSigtermIsStillKilled() async throws {
        // Terminate() alone does nothing to a process that ignores SIGTERM, so without
        // escalating to SIGKILL the pipe read below would never see EOF and this call
        // would hang forever — taking every other adb operation down with it, since
        // nothing distinguishes this call from any other. If this test times out rather
        // than completing quickly, the escalation regressed.
        let elapsed = try await ContinuousClock().measure {
            _ = try await shell.run(["-c", Self.stubbornProcessScript], timeout: .seconds(1))
        }
        #expect(elapsed < .seconds(10))
    }

    @Test("Cancellation kills a process that ignores SIGTERM")
    func cancellationKillsStubbornProcess() async throws {
        // Mirrors what happens when the user presses Cancel while an adb call that
        // won't die gracefully is in flight.
        let task = Task {
            try await shell.run(["-c", Self.stubbornProcessScript], timeout: .seconds(60))
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()

        let elapsed = try await ContinuousClock().measure {
            _ = try? await task.value
        }
        #expect(elapsed < .seconds(10))
    }

    @Test("Independent calls don't serialize behind one another")
    func callsRunConcurrentlyNotSerially() async throws {
        // ADBClient used to be an actor with no mutable state to protect, which meant
        // every call queued behind whichever one happened to be running — including a
        // stuck one. If two independent one-second calls take close to two seconds
        // combined rather than close to one, that serialization is back.
        let elapsed = try await ContinuousClock().measure {
            async let first = shell.run(["-c", "sleep 1"], timeout: .seconds(10))
            async let second = shell.run(["-c", "sleep 1"], timeout: .seconds(10))
            _ = try await (first, second)
        }
        #expect(elapsed < .seconds(3), "the two calls should overlap, not queue")
    }

    @Test("Push timeout has a floor for small files and scales for large ones")
    func pushTimeoutCalculation() {
        #expect(ADBClient.pushTimeout(forBytes: 0) == .seconds(60))
        #expect(ADBClient.pushTimeout(forBytes: 1_000) == .seconds(60))

        // 5 GB at the 500 KB/s floor is 10,000 seconds — finite, but generous enough
        // not to falsely kill a real, slow-but-progressing transfer.
        let fiveGB: Int64 = 5_000_000_000
        #expect(ADBClient.pushTimeout(forBytes: fiveGB) == .seconds(10_000))
    }
}
