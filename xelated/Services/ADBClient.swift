import Darwin
import Foundation

nonisolated struct AndroidDevice: Sendable, Identifiable, Hashable {
    enum State: String, Sendable {
        case ready = "device"
        case unauthorized
        case offline
        case unknown

        var isUsable: Bool { self == .ready }

        var explanation: String? {
            switch self {
            case .ready: nil
            case .unauthorized: "Unlock the phone and tap Allow on the USB debugging prompt."
            case .offline: "The phone is connected but not responding. Try reconnecting the cable."
            case .unknown: "The phone is in an unexpected state."
            }
        }
    }

    let serial: String
    let state: State
    let model: String?

    var id: String { serial }
    var displayName: String { model?.replacingOccurrences(of: "_", with: " ") ?? serial }
}

nonisolated enum ADBError: LocalizedError {
    case adbNotFound(URL)
    case commandFailed(command: String, status: Int32, message: String)
    case unreadableOutput(command: String, output: String)

    var errorDescription: String? {
        switch self {
        case .adbNotFound(let url):
            "Couldn't find adb at \(url.path(percentEncoded: false)). "
                + "Install the Android platform tools, or point Xelated at the right path."
        case .commandFailed(let command, let status, let message):
            "adb \(command) failed (\(status)): \(message)"
        case .unreadableOutput(let command, let output):
            "Couldn't make sense of the output of adb \(command): \(output)"
        }
    }
}

/// Thin async wrapper over the `adb` command-line tool.
///
/// Works with any Android device, not just a Pixel — the phone is only acting as an
/// upload mule for whichever photo service is set to back up its camera folder.
///
/// A plain `Sendable` class, not an actor: it holds no mutable state, and every call
/// spawns its own independent `Process`. Concurrent `adb` invocations against the same
/// device are normal and well-supported. Making this an actor would buy nothing but a
/// single point of failure — one stuck call (a wedged `dumpsys`, a stalled push) would
/// serialize behind it forever, freezing every other adb operation including the ones
/// Cancel would need to make.
final class ADBClient: Sendable {
    /// Staging folder on the device.
    ///
    /// Confirmed against a real Pixel running Storage Saver: Google Photos' "Back up
    /// other device folders" picker only lists a small set of OS-blessed folders
    /// (Camera, Screenshots) unless the app holds "All files access" — and recent
    /// Google Photos versions don't expose a Settings toggle for that permission at
    /// all, so it can't be granted even by hand. A custom `Pictures/Xelated` folder
    /// was tried first and, consistent with that, never appeared as an option. Reusing
    /// the real Screenshots folder was the one thing confirmed to actually show up.
    ///
    /// Because this is a folder the phone itself writes real screenshots into,
    /// `AndroidBackupService` tracks exactly which remote paths Xelated pushed via the
    /// ledger and only ever touches those — see `unconfirmedRemotePaths()`.
    static let remoteDirectory = "/sdcard/Pictures/Screenshots"

    static let defaultExecutable = URL(filePath: "/opt/homebrew/bin/adb")

    private let executableURL: URL

    init(executableURL: URL = ADBClient.defaultExecutable) {
        self.executableURL = executableURL
    }

    // MARK: - Device discovery

    func checkAvailable() async throws {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ADBError.adbNotFound(executableURL)
        }
    }

    func devices() async throws -> [AndroidDevice] {
        try await checkAvailable()
        let result = try await run(["devices", "-l"], timeout: .seconds(20))
        try result.throwIfFailed(command: "devices")

        return result.stdout
            .split(separator: "\n")
            .dropFirst()  // "List of devices attached"
            .compactMap { Self.parseDeviceLine(String($0)) }
    }

    static func parseDeviceLine(_ line: String) -> AndroidDevice? {
        let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count >= 2 else { return nil }

        let model = fields.dropFirst(2)
            .first { $0.hasPrefix("model:") }
            .map { String($0.dropFirst("model:".count)) }

        return AndroidDevice(
            serial: fields[0],
            state: AndroidDevice.State(rawValue: fields[1]) ?? .unknown,
            model: model
        )
    }

    // MARK: - Storage

    /// Free bytes on the volume holding `path`.
    ///
    /// Uses `stat -f` rather than `df`: df's column layout and units shift between
    /// toolbox, toybox and busybox builds, while stat can be asked for exactly two
    /// numbers. The format string deliberately contains no spaces — adb joins arguments
    /// and hands them to the device's shell, which would otherwise split it.
    func freeBytes(serial: String, path: String = "/sdcard") async throws -> Int64 {
        let result = try await run(
            ["-s", serial, "shell", "stat", "-f", "-c", "%a,%S", Self.quoted(path)],
            timeout: .seconds(20)
        )
        try result.throwIfFailed(command: "stat -f")

        let parts = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",")
        guard parts.count == 2,
              let blocks = Int64(parts[0]),
              let blockSize = Int64(parts[1])
        else {
            throw ADBError.unreadableOutput(command: "stat -f", output: result.stdout)
        }
        return blocks * blockSize
    }

    // MARK: - Files

    func makeRemoteDirectory(serial: String, path: String = ADBClient.remoteDirectory) async throws {
        let result = try await run(
            ["-s", serial, "shell", "mkdir", "-p", Self.quoted(path)],
            timeout: .seconds(20)
        )
        try result.throwIfFailed(command: "mkdir -p")
    }

    /// Push one file.
    ///
    /// The timeout is generous and scales with size rather than being absent: a large
    /// video over USB 2 legitimately takes minutes, but a transfer that's genuinely
    /// stalled — a half-unplugged cable, a suspended USB port, a wedged phone — needs to
    /// fail eventually and get retried next run, rather than hang forever.
    func push(serial: String, localURL: URL, remotePath: String, byteSize: Int64) async throws {
        let result = try await run(
            ["-s", serial, "push", localURL.path(percentEncoded: false), remotePath],
            timeout: Self.pushTimeout(forBytes: byteSize)
        )
        try result.throwIfFailed(command: "push")
    }

    /// A conservative floor of 500 KB/s — well below what even a bad USB 2 connection
    /// should sustain — with a 60-second minimum so tiny files aren't cut close.
    static func pushTimeout(forBytes bytes: Int64) -> Duration {
        let minimumBytesPerSecond = 500_000.0
        return .seconds(max(60, Double(bytes) / minimumBytesPerSecond))
    }

    /// Size of a file on the device, or nil if it isn't there.
    func remoteFileSize(serial: String, path: String) async throws -> Int64? {
        let result = try await run(
            ["-s", serial, "shell", "stat", "-c", "%s", Self.quoted(path)],
            timeout: .seconds(30)
        )
        guard result.status == 0 else { return nil }
        return Int64(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func listRemoteDirectory(
        serial: String,
        path: String = ADBClient.remoteDirectory
    ) async throws -> [String] {
        let result = try await run(
            ["-s", serial, "shell", "ls", "-A", Self.quoted(path)],
            timeout: .seconds(30)
        )
        // A missing folder is not an error here — it just means nothing is staged.
        guard result.status == 0 else { return [] }
        return result.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func removeRemoteFiles(serial: String, paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        let result = try await run(
            ["-s", serial, "shell", "rm", "-f"] + paths.map(Self.quoted),
            timeout: .seconds(120)
        )
        try result.throwIfFailed(command: "rm")
    }

    /// Ask the media scanner to notice the staged files.
    ///
    /// Recent Android indexes anything written through the FUSE layer automatically, so
    /// this is belt and braces — failure is ignored rather than surfaced.
    func requestMediaScan(serial: String, path: String = ADBClient.remoteDirectory) async throws {
        _ = try? await run(
            ["-s", serial, "shell", "am", "broadcast",
             "-a", "android.intent.action.MEDIA_SCANNER_SCAN_FILE",
             "-d", "file://\(path)"],
            timeout: .seconds(20)
        )
    }

    // MARK: - Upload status (advisory only)

    enum BackupHint: Sendable, Equatable {
        case inProgress
        case noNotification
        case indeterminate

        var summary: String {
            switch self {
            case .inProgress: "Google Photos is still showing a backup notification."
            case .noNotification: "No Google Photos backup notification on screen."
            case .indeterminate: "Couldn't read the phone's notifications."
            }
        }
    }

    /// Peek at whether the photo app is still advertising an upload in its notifications.
    ///
    /// Strictly a hint, never a verdict. There's no API that reports whether Google
    /// Photos has finished uploading, so this scrapes `dumpsys notification`, which is
    /// an undocumented format that varies by Android version and says nothing once the
    /// notification is dismissed. `.noNotification` emphatically does not prove the
    /// upload finished — only the person looking at the phone can confirm that.
    func backupNotificationHint(
        serial: String,
        packageName: String = "com.google.android.apps.photos"
    ) async -> BackupHint {
        guard let result = try? await run(
            ["-s", serial, "shell", "dumpsys", "notification", "--noredact"],
            timeout: .seconds(30)
        ), result.status == 0, !result.stdout.isEmpty else {
            return .indeterminate
        }

        let records = result.stdout
            .components(separatedBy: "NotificationRecord(")
            .filter { $0.contains(packageName) }
        guard !records.isEmpty else { return .noNotification }

        let activeWords = ["backing up", "backing-up", "preparing", "uploading"]
        let busy = records.contains { record in
            let lowered = record.lowercased()
            return activeWords.contains { lowered.contains($0) }
        }
        return busy ? .inProgress : .noNotification
    }

    // MARK: - Process plumbing

    /// Internal rather than private so the process plumbing can be exercised directly
    /// against a stand-in executable, without a phone attached.
    struct CommandResult {
        let command: String
        let status: Int32
        let stdout: String
        let stderr: String

        func throwIfFailed(command: String) throws {
            guard status != 0 else { return }
            let message = stderr.isEmpty ? stdout : stderr
            throw ADBError.commandFailed(
                command: command,
                status: status,
                message: message.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    /// Single-quote a path for the device's shell.
    ///
    /// Needed because `adb shell` joins its arguments into one string and hands it to
    /// sh on the phone, so a filename like `Screen Recording 2026-09-16.mov` would
    /// otherwise arrive as three separate arguments. `adb push` takes paths as real
    /// argv and must not be quoted this way.
    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    func run(_ arguments: [String], timeout: Duration?) async throws -> CommandResult {
        try await checkAvailable()

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()

        let timeoutTask: Task<Void, Never>? = timeout.map { limit in
            Task {
                try? await Task.sleep(for: limit)
                if process.isRunning { Self.forceTerminate(process) }
            }
        }
        defer { timeoutTask?.cancel() }

        // Drain both pipes concurrently. Reading one to EOF before starting on the other
        // deadlocks the moment output exceeds the 64 KiB pipe buffer, which a chatty
        // `adb push` will do.
        let (outData, errData) = await withTaskCancellationHandler {
            async let stdout = Self.readToEnd(outPipe)
            async let stderr = Self.readToEnd(errPipe)
            return await (stdout, stderr)
        } onCancel: {
            Self.forceTerminate(process)
        }

        process.waitUntilExit()  // both pipes are at EOF, so this returns promptly

        return CommandResult(
            command: arguments.joined(separator: " "),
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    /// Sends SIGTERM, then escalates to SIGKILL if the process hasn't died within a
    /// short grace period.
    ///
    /// SIGTERM alone isn't reliable here: an `adb` invocation wedged on a stalled USB
    /// transfer or an unresponsive shell on the phone can simply not respond to it. When
    /// that happens the pipe reads below never see EOF, `run` never returns, and — since
    /// nothing else about this call is special — every other adb operation waiting on
    /// the same underlying connection effectively wedges too. SIGKILL cannot be caught
    /// or ignored, so this is what actually guarantees the timeout (and cancellation)
    /// have teeth.
    private static func forceTerminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()

        let pid = process.processIdentifier
        Task {
            try? await Task.sleep(for: .seconds(3))
            if process.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }

    private static func readToEnd(_ pipe: Pipe) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                continuation.resume(returning: data)
            }
        }
    }
}
