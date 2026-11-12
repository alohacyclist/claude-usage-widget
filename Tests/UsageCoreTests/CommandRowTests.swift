import Foundation
import Testing
@testable import UsageCore

@Suite struct CommandRunnerTests {
    @Test func parsesTheLastNonEmptyLine() throws {
        let output = """
        warming up
        {"title": "Today", "value": "4:05h", "detail": "2 sessions active", "active": true}

        """
        let rows = try CommandRunner.parse(output)
        #expect(rows == [CommandStatus(title: "Today", value: "4:05h", detail: "2 sessions active", active: true)])
    }

    @Test func detailActiveAndLevelAreOptional() throws {
        let rows = try CommandRunner.parse(#"{"title": "Build", "value": "green"}"#)
        #expect(rows == [CommandStatus(title: "Build", value: "green")])
    }

    @Test func parsesAnArrayAsSeveralRows() throws {
        let rows = try CommandRunner.parse(#"[{"title": "A", "value": "1"}, {"title": "B", "value": "2", "level": "warning"}]"#)
        #expect(rows == [CommandStatus(title: "A", value: "1"), CommandStatus(title: "B", value: "2", level: .warning)])
    }

    @Test func parsesTheHighlightFlag() throws {
        let rows = try CommandRunner.parse(#"{"title": "A", "value": "1", "highlight": true}"#)
        #expect(rows == [CommandStatus(title: "A", value: "1", highlight: true)])
    }

    @Test func rejectsAnUnknownLevel() {
        #expect(throws: CommandError.invalidOutput) {
            try CommandRunner.parse(#"{"title": "A", "value": "1", "level": "panic"}"#)
        }
    }

    @Test func highlightsAreTheFirstRowAndAlerts() {
        let rows = [
            CommandStatus(title: "A", value: "1", level: .warning),
            CommandStatus(title: "B", value: "2", level: .ok),
            CommandStatus(title: "C", value: "3"),
            CommandStatus(title: "D", value: "4", level: .critical),
            CommandStatus(title: "E", value: "5", highlight: true),
            CommandStatus(title: "F", value: "6", highlight: false),
        ]
        #expect(rows.highlights.map(\.title) == ["A", "D", "E"])
        #expect([CommandStatus]().highlights.isEmpty)
    }

    @Test func rejectsOutputWithoutAStatusLine() {
        #expect(throws: CommandError.invalidOutput) { try CommandRunner.parse("") }
        #expect(throws: CommandError.invalidOutput) { try CommandRunner.parse("{\"title\": 1}\nnot json") }
    }

    @Test func runsTheCommandInZsh() async throws {
        let status = try await CommandRunner.run(#"print 'noise'; print '{"title":"T","value":"'$((6*7))'"}'"#)
        #expect(status.map(\.value) == ["42"])
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
        #expect(!store.showsCommandRows)
        #expect(store.commandRows.isEmpty)
    }

    @Test @MainActor func keepsTheLastValueWhenTheCommandFails() async {
        let store = store(command: #"[[ -e "$TMPDIR/claude-usage-test-fail" ]] && exit 1; print '{"title":"T","value":"1"}'"#)
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("claude-usage-test-fail")
        try? FileManager.default.removeItem(at: marker)
        await store.refreshCommand()
        #expect(store.showsCommandRows)
        #expect(store.commandRows.map(\.value) == ["1"])

        FileManager.default.createFile(atPath: marker.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: marker) }
        await store.refreshCommand()
        #expect(store.commandRows.map(\.value) == ["1"])
        #expect(store.commandError == .failed(status: 1, message: ""))
    }

    @Test @MainActor func skipsAFreshValue() async {
        let store = store(command: #"print "{\"title\":\"T\",\"value\":\"$RANDOM$RANDOM\"}""#)
        await store.refreshCommand()
        let first = store.commandRows
        await store.refreshCommand(maxAge: 300)
        #expect(store.commandRows == first)
        await store.refreshCommand()
        #expect(store.commandRows != first)
    }
}
