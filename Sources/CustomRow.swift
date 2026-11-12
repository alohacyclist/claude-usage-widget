import Foundation

/// One extra row fed by a user-configured shell command, e.g. tracked working time.
/// The command prints a JSON object as its last non-empty stdout line:
/// `{"title": "Today", "value": "4:05h", "detail": "2 sessions active", "active": true}`.
struct CommandStatus: Equatable, Decodable {
    let title: String
    let value: String
    let detail: String?
    /// Shown as a green (true) or gray (false) dot; no dot when missing.
    let active: Bool?
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
    static func parse(_ output: String) throws -> CommandStatus {
        let line = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        guard let line, let status = try? JSONDecoder().decode(CommandStatus.self, from: Data(line.utf8))
        else { throw CommandError.invalidOutput }
        return status
    }

    /// Runs `command` with `/bin/zsh -c` off the main thread.
    static func run(_ command: String, timeout: TimeInterval = 30) async throws -> CommandStatus {
        let output = try await Task.detached { try execute(command, timeout: timeout) }.value
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
