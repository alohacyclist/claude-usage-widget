import Foundation
import Testing
@testable import UsageCore

private let hour: TimeInterval = 3600
private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

/// A 5-hour window whose start lies `elapsed` seconds before `now`.
private func session(_ percent: Double, elapsed: TimeInterval) -> UsageWindow {
    UsageWindow(percent: percent, resetsAt: now.addingTimeInterval(5 * hour - elapsed), length: 5 * hour)
}

@Suite struct ForecastTests {
    @Test func extrapolatesTheAverageRateToTheReset() {
        #expect(session(40, elapsed: 2 * hour).projectedPercentAtReset(at: now) == 100)
        #expect(session(10, elapsed: 4 * hour).projectedPercentAtReset(at: now) == 12.5)
    }

    @Test func staysQuietWhileTheWindowIsYoung() {
        #expect(session(30, elapsed: 10 * 60).projectedPercentAtReset(at: now) == nil)
        #expect(session(30, elapsed: 10 * 60).projectedLimitDate(at: now) == nil)
    }

    @Test func predictsWhenTheLimitIsHit() {
        // 50 % in 2 h is 25 %/h, so the remaining 50 % last another 2 h.
        #expect(session(50, elapsed: 2 * hour).projectedLimitDate(at: now) == now.addingTimeInterval(2 * hour))
    }

    @Test func noLimitDateWhenOnPaceOrAlreadyFull() {
        #expect(session(30, elapsed: 2 * hour).projectedLimitDate(at: now) == nil)
        #expect(session(100, elapsed: 2 * hour).projectedLimitDate(at: now) == nil)
    }

    @Test func elapsedFractionIsClamped() {
        #expect(session(0, elapsed: hour).elapsedFraction(at: now) == 0.2)
        #expect(session(0, elapsed: 6 * hour).elapsedFraction(at: now) == 1)
        #expect(UsageWindow(percent: 0, resetsAt: nil, length: hour).elapsedFraction(at: now) == nil)
    }
}

@Suite struct DecodingTests {
    @Test func parsesMicrosecondsAndRoundsToTheMinute() throws {
        let date = try #require(UsageAPI.parseDate("2026-11-09T15:29:59.900000+00:00"))
        #expect(date == ISO8601DateFormatter().date(from: "2026-11-09T15:30:00Z"))
    }

    @Test func decodesBothWindowsAndIgnoresUnknownFields() throws {
        let json = """
        {"five_hour": {"utilization": 72.0, "resets_at": "2026-11-09T16:30:00.286111+00:00"},
         "seven_day": {"utilization": 25.0, "resets_at": "2026-11-13T15:00:00+00:00"},
         "seven_day_opus": null, "extra_usage": {"is_enabled": false}}
        """
        let result = try UsageAPI.decode(Data(json.utf8))
        #expect(result.session?.percent == 72)
        #expect(result.session?.length == 5 * hour)
        #expect(result.weekly?.percent == 25)
        #expect(result.weekly?.length == 7 * 24 * hour)
    }

    @Test func missingUtilizationMeansNoWindow() throws {
        let result = try UsageAPI.decode(Data(#"{"five_hour": {"utilization": null, "resets_at": null}}"#.utf8))
        #expect(result.session == nil)
        #expect(result.weekly == nil)
    }

    @Test @MainActor func planWithoutSessionWindowHidesTheSessionRow() throws {
        let json = #"{"five_hour": null, "seven_day": {"utilization": 15.0, "resets_at": "2026-11-13T16:00:00.261959+00:00"}}"#
        let result = try UsageAPI.decode(Data(json.utf8))
        #expect(result.session == nil)
        let store = UsageStore.sample(session: result.session, weekly: result.weekly, updated: Date())
        #expect(!store.showsSession)
    }

    @Test @MainActor func sessionRowStaysAsPlaceholderBeforeTheFirstFetch() {
        #expect(UsageStore(defaults: UserDefaults(suiteName: "test") ?? .standard).showsSession)
    }
}

@Suite struct BackoffTests {
    @Test func doublesUpToAnHour() {
        var backoff = Backoff()
        var delays: [TimeInterval] = []
        for _ in 0..<7 {
            backoff = backoff.recordingRateLimit(retryAt: nil, base: 120, now: now)
            delays.append(backoff.until!.timeIntervalSince(now))
        }
        #expect(delays == [120, 240, 480, 960, 1920, 3600, 3600])
    }

    @Test func serverRetryAfterWins() {
        let retryAt = now.addingTimeInterval(42)
        #expect(Backoff().recordingRateLimit(retryAt: retryAt, base: 120, now: now).until == retryAt)
    }

    @Test func blocksUntilTheRetryDate() {
        let backoff = Backoff().recordingRateLimit(retryAt: nil, base: 120, now: now)
        #expect(!backoff.allows(at: now.addingTimeInterval(60)))
        #expect(backoff.allows(at: now.addingTimeInterval(120)))
        #expect(Backoff().allows(at: now))
    }

    @Test func readsRetryAfterSeconds() {
        #expect(UsageAPI.retryDate("30", now: now) == now.addingTimeInterval(30))
        #expect(UsageAPI.retryDate("Wed, 21 Oct 2015 07:28:00 GMT", now: now) == nil)
        #expect(UsageAPI.retryDate(nil, now: now) == nil)
    }
}
