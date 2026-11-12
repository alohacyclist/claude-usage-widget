import Foundation

/// Extra rows fed by a user-configured shell command, e.g. tracked working time.
/// The command prints a JSON object, or an array of them for several rows, as its last non-empty stdout line:
/// `{"title": "Today", "value": "4:05h", "detail": "2 sessions active", "active": true}`.
struct CommandStatus: Equatable, Decodable {
    enum Level: String, Equatable, Decodable {
        case ok, warning, critical
    }

    let title: String
    let value: String
    var detail: String? = nil
    /// Shown as a green (true) or gray (false) dot; no dot when missing.
    var active: Bool? = nil
    /// `warning` and `critical` color the dot and the value, and keep the row visible in the compact views.
    var level: Level? = nil
    /// Keeps the row in the compact pill and the menu bar even without an alert.
    var highlight: Bool? = nil

    var isAlert: Bool { level == .warning || level == .critical }
}

extension [CommandStatus] {
    /// What the compact pill and the menu bar show: the first row plus every highlighted or alerting row.
    var highlights: [CommandStatus] {
        enumerated().filter { $0.offset == 0 || $0.element.isAlert || $0.element.highlight == true }.map(\.element)
    }
}

enum CommandError: LocalizedError, Equatable {
    case failed(status: Int32, message: String)
    case timedOut(seconds: Int)
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .failed(let status, ""):
            String(localized: "Command failed with exit code \(Int(status)).")
        case .failed(_, let message):
            String(localized: "Command failed: \(message)")
        case .timedOut(let seconds):
            String(localized: "Command took longer than \(seconds) s.")
        case .invalidOutput:
            String(localized: "Command printed no JSON status line.")
        }
    }
}

enum CommandRunner {
    static func parse(_ output: String) throws -> [CommandStatus] {
        let line = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        guard let data = line.map({ Data($0.utf8) }) else { throw CommandError.invalidOutput }
        let decoder = JSONDecoder()
        if let rows = try? decoder.decode([CommandStatus].self, from: data) { return rows }
        guard let row = try? decoder.decode(CommandStatus.self, from: data) else { throw CommandError.invalidOutput }
        return [row]
    }

    /// Runs `command` with `/bin/zsh -c` on a GCD thread: `execute` blocks until the command ends,
    /// which must not tie up a thread of Swift's small cooperative pool.
    static func run(_ command: String, timeout: TimeInterval = 30) async throws -> [CommandStatus] {
        let output = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try execute(command, timeout: timeout) })
            }
        }
        return try parse(output)
    }

    private static func execute(_ command: String, timeout: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        // Process starts its child in a new process group, so this also stops pipelines and subshells.
        let started = Date()
        let pid = process.processIdentifier
        let killer = DispatchWorkItem { kill(-pid, SIGKILL) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        defer { killer.cancel() }

        // Drain stderr in parallel so a chatty command cannot fill the pipe and block.
        var errorData = Data()
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global().async {
            errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            drained.leave()
        }
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        process.waitUntilExit()

        if process.terminationReason == .uncaughtSignal, Date().timeIntervalSince(started) >= timeout {
            throw CommandError.timedOut(seconds: Int(timeout))
        }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self)
                .split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            throw CommandError.failed(status: process.terminationStatus, message: message)
        }
        return String(decoding: outputData, as: UTF8.self)
    }
}
