import AppKit
import Foundation

struct UsageWindow: Equatable {
    let percent: Double
    let resetsAt: Date?
    let length: TimeInterval

    var start: Date? { resetsAt?.addingTimeInterval(-length) }

    func elapsedFraction(at now: Date) -> Double? {
        guard let start else { return nil }
        return min(max(now.timeIntervalSince(start) / length, 0), 1)
    }

    /// Linear extrapolation of the average burn rate since the window started;
    /// nil while the window is too young to judge.
    func projectedPercentAtReset(at now: Date) -> Double? {
        guard let start else { return nil }
        let elapsed = now.timeIntervalSince(start)
        guard elapsed > length * 0.05 else { return nil }
        return percent * length / elapsed
    }

    /// When the limit would be hit at the current pace, if that happens before the reset.
    func projectedLimitDate(at now: Date) -> Date? {
        guard percent < 100, let start,
              let projected = projectedPercentAtReset(at: now), projected > 100
        else { return nil }
        let rate = percent / now.timeIntervalSince(start)
        return now.addingTimeInterval((100 - percent) / rate)
    }
}

enum UsageError: LocalizedError, Equatable {
    case noCredentials
    case unauthorized
    case rateLimited(retryAt: Date?)
    case http(Int)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .noCredentials:
            String(localized: "No Claude Code login found in the keychain.")
        case .unauthorized:
            String(localized: "Token expired – open Claude Code once.")
        case .rateLimited(let retryAt?):
            String(localized: "Rate limited – next try at \(retryAt.formatted(date: .omitted, time: .shortened)).")
        case .rateLimited(nil):
            String(localized: "Rate limited – retrying shortly.")
        case .http(let code):
            String(localized: "Server responded with HTTP \(code).")
        case .network(let message):
            String(localized: "Offline: \(message)")
        }
    }
}

enum UsageAPI {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func fetch() async throws -> (session: UsageWindow?, weekly: UsageWindow?) {
        let token = try readAccessToken()
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UsageError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw UsageError.http(0) }
        switch http.statusCode {
        case 200: return try decode(data)
        case 401, 403: throw UsageError.unauthorized
        case 429: throw UsageError.rateLimited(retryAt: retryDate(http.value(forHTTPHeaderField: "Retry-After")))
        default: throw UsageError.http(http.statusCode)
        }
    }

    static func decode(_ data: Data) throws -> (session: UsageWindow?, weekly: UsageWindow?) {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return (
            payload.five_hour?.window(length: 5 * 3600),
            payload.seven_day?.window(length: 7 * 86400)
        )
    }

    /// Retry-After in seconds; HTTP-date values are rare enough to fall back to our own backoff.
    static func retryDate(_ header: String?, now: Date = Date()) -> Date? {
        guard let header, let seconds = TimeInterval(header.trimmingCharacters(in: .whitespaces)), seconds > 0
        else { return nil }
        return now.addingTimeInterval(seconds)
    }

    /// The API sends microseconds (rejected by ISO8601DateFormatter) and sometimes lands just before
    /// the full minute (15:29:59.9 instead of 15:30), so round to the minute.
    static func parseDate(_ value: String) -> Date? {
        let trimmed = value.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        guard let date = ISO8601DateFormatter().date(from: trimmed) else { return nil }
        return Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded() * 60)
    }

    /// Claude Code keeps its OAuth token in the login keychain and refreshes it itself, so we only read.
    /// Refreshing here would rotate the refresh token and log Claude Code out.
    private static func readAccessToken() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let credentials = try? JSONDecoder().decode(Credentials.self, from: data)
        else { throw UsageError.noCredentials }
        return credentials.claudeAiOauth.accessToken
    }

    private struct Credentials: Decodable {
        struct OAuth: Decodable { let accessToken: String }
        let claudeAiOauth: OAuth
    }

    private struct Payload: Decodable {
        struct Limit: Decodable {
            let utilization: Double?
            let resets_at: String?

            func window(length: TimeInterval) -> UsageWindow? {
                guard let utilization else { return nil }
                return UsageWindow(percent: utilization, resetsAt: resets_at.flatMap(parseDate), length: length)
            }
        }

        let five_hour: Limit?
        let seven_day: Limit?
    }
}

/// Exponential backoff after HTTP 429; the endpoint is known to keep rate limiting aggressive pollers.
struct Backoff: Equatable {
    static let maxDelay: TimeInterval = 3600

    private(set) var strikes = 0
    private(set) var until: Date?

    func allows(at now: Date) -> Bool { until.map { now >= $0 } ?? true }

    /// Server-provided retry date wins; otherwise base, 2x, 4x … capped at an hour.
    func recordingRateLimit(retryAt: Date?, base: TimeInterval, now: Date) -> Backoff {
        let delay = min(base * pow(2, Double(strikes)), Self.maxDelay)
        return Backoff(strikes: strikes + 1, until: retryAt ?? now.addingTimeInterval(delay))
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var session: UsageWindow?
    @Published private(set) var weekly: UsageWindow?
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var error: UsageError?
    @Published private(set) var isLoading = false
    @Published private(set) var commandStatus: CommandStatus?
    @Published private(set) var commandError: CommandError?

    @Published var showFloating: Bool { didSet { defaults.set(showFloating, forKey: Keys.showFloating) } }
    @Published var showPercentInMenuBar: Bool { didSet { defaults.set(showPercentInMenuBar, forKey: Keys.menuBarText) } }
    @Published var compact: Bool { didSet { defaults.set(compact, forKey: Keys.compact) } }

    /// Plans without a 5-hour window get `five_hour: null`; until the first successful fetch both rows stay as placeholders.
    var showsSession: Bool { session != nil || lastUpdate == nil }
    var showsCommandRow: Bool { customCommand != nil || commandStatus != nil }

    /// Shell command for the extra row; set with `defaults write`, read once at launch.
    let customCommand: String?

    private let defaults: UserDefaults
    private let refreshInterval: TimeInterval = 120
    private let commandInterval: TimeInterval
    private var backoff = Backoff()
    private var timer: Timer?
    private var commandTimer: Timer?
    private var commandUpdate: Date?
    private var isRunningCommand = false

    enum Keys {
        static let showFloating = "showFloating"
        static let menuBarText = "showPercentInMenuBar"
        static let compact = "compact"
        static let customCommand = "customRowCommand"
        static let customInterval = "customRowInterval"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showFloating = defaults.object(forKey: Keys.showFloating) as? Bool ?? true
        showPercentInMenuBar = defaults.object(forKey: Keys.menuBarText) as? Bool ?? true
        compact = defaults.object(forKey: Keys.compact) as? Bool ?? false
        let command = defaults.string(forKey: Keys.customCommand)?.trimmingCharacters(in: .whitespacesAndNewlines)
        customCommand = command?.isEmpty == false ? command : nil
        commandInterval = max(defaults.object(forKey: Keys.customInterval) as? Double ?? 3600, 60)
    }

    /// Fixed data for screenshots and previews; never polls.
    static func sample(
        session: UsageWindow?, weekly: UsageWindow?, updated: Date, command: CommandStatus? = nil
    ) -> UsageStore {
        let store = UsageStore(defaults: UserDefaults(suiteName: "sample") ?? .standard)
        store.session = session
        store.weekly = weekly
        store.lastUpdate = updated
        store.commandStatus = command
        return store
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshAll(commandMaxAge: 300) }
        }
        if customCommand != nil {
            commandTimer = Timer.scheduledTimer(withTimeInterval: commandInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.refreshCommand() }
            }
        }
        Task { await refreshAll() }
    }

    /// Opening the menu refreshes usage after 30 s and the command row after 5 min.
    func refreshIfStale(maxAge: TimeInterval = 30) async {
        async let command: Void = refreshCommand(maxAge: 300)
        if lastUpdate == nil || Date().timeIntervalSince(lastUpdate ?? .distantPast) >= maxAge {
            await refresh()
        }
        await command
    }

    func refreshAll(commandMaxAge: TimeInterval = 0) async {
        async let command: Void = refreshCommand(maxAge: commandMaxAge)
        await refresh()
        await command
    }

    func refreshCommand(maxAge: TimeInterval = 0) async {
        guard let customCommand, !isRunningCommand else { return }
        if let commandUpdate, Date().timeIntervalSince(commandUpdate) < maxAge { return }
        isRunningCommand = true
        defer { isRunningCommand = false }
        do {
            commandStatus = try await CommandRunner.run(customCommand)
            commandError = nil
        } catch let error as CommandError {
            commandError = error
        } catch {
            commandError = .failed(status: -1, message: error.localizedDescription)
        }
        commandUpdate = Date()
    }

    func refresh() async {
        guard !isLoading, backoff.allows(at: Date()) else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await UsageAPI.fetch()
            session = result.session
            weekly = result.weekly
            lastUpdate = Date()
            error = nil
            backoff = Backoff()
        } catch UsageError.rateLimited(let retryAt) {
            backoff = backoff.recordingRateLimit(retryAt: retryAt, base: refreshInterval, now: Date())
            error = .rateLimited(retryAt: backoff.until)
        } catch let usageError as UsageError {
            error = usageError
        } catch {
            self.error = .network(error.localizedDescription)
        }
    }
}
