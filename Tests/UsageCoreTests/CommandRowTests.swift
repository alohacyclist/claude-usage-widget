import Foundation
import Testing
@testable import UsageCore

@Suite struct CommandRunnerTests {
    @Test func parsesTheLastNonEmptyLine() throws {
        let output = """
        warming up
        {"title": "Today", "value": "4:05h", "detail": "2 sessions active", "active": true}

        """
        let status = try CommandRunner.parse(output)
        #expect(status == CommandStatus(title: "Today", value: "4:05h", detail: "2 sessions active", active: true))
    }

    @Test func detailAndActiveAreOptional() throws {
        let status = try CommandRunner.parse(#"{"title": "Build", "value": "green"}"#)
        #expect(status.detail == nil)
        #expect(status.active == nil)
    }

    @Test func rejectsOutputWithoutAStatusLine() {
        #expect(throws: CommandError.invalidOutput) { try CommandRunner.parse("") }
        #expect(throws: CommandError.invalidOutput) { try CommandRunner.parse("{\"title\": 1}\nnot json") }
    }

    @Test func runsTheCommandInZsh() async throws {
        let status = try await CommandRunner.run(#"print 'noise'; print '{"title":"T","value":"'$((6*7))'"}'"#)
        #expect(status.value == "42")
    }

    @Test func reportsTheLastStderrLineOnFailure() async {
        await #expect(throws: CommandError.failed(status: 3, message: "boom")) {
            try await CommandRunner.run("print -u2 starting; print -u2 boom; exit 3")
        }
    }

    @Test func killsTheWholePipelineOnTimeout() async {
        let started = Date()
        await #expect(throws: CommandError.timedOut(seconds: 1)) {
            try await CommandRunner.run("sleep 20 | cat", timeout: 1)
        }
        #expect(Date().timeIntervalSince(started) < 5)
    }
}

@Suite struct CommandStoreTests {
    @MainActor private func store(command: String?) -> UsageStore {
        let defaults = UserDefaults(suiteName: "command-row-\(UUID())")!
        defaults.set(command, forKey: UsageStore.Keys.customCommand)
        return UsageStore(defaults: defaults)
    }

    @Test @MainActor func noCommandMeansNoRow() async {
        let store = store(command: "  ")
        await store.refreshCommand()
        #expect(!store.showsCommandRow)
        #expect(store.commandStatus == nil)
    }

    @Test @MainActor func keepsTheLastValueWhenTheCommandFails() async {
        let store = store(command: #"[[ -e "$TMPDIR/claude-usage-test-fail" ]] && exit 1; print '{"title":"T","value":"1"}'"#)
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("claude-usage-test-fail")
        try? FileManager.default.removeItem(at: marker)
        await store.refreshCommand()
        #expect(store.showsCommandRow)
        #expect(store.commandStatus?.value == "1")

        FileManager.default.createFile(atPath: marker.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: marker) }
        await store.refreshCommand()
        #expect(store.commandStatus?.value == "1")
        #expect(store.commandError == .failed(status: 1, message: ""))
    }

    @Test @MainActor func skipsAFreshValue() async {
        let store = store(command: #"print "{\"title\":\"T\",\"value\":\"$RANDOM$RANDOM\"}""#)
        await store.refreshCommand()
        let first = store.commandStatus
        await store.refreshCommand(maxAge: 300)
        #expect(store.commandStatus == first)
        await store.refreshCommand()
        #expect(store.commandStatus != first)
    }
}
