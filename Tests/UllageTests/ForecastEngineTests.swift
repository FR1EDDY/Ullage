import XCTest
@testable import Ullage

final class ForecastEngineTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ForecastEngineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() throws -> SnapshotStore {
        try SnapshotStore(url: directory.appendingPathComponent("usage.sqlite"))
    }

    // MARK: - End to end over the real store

    /// The engine's only job is choosing which series to feed the pure
    /// analytics, so this checks the plumbing rather than the maths.
    func testProducesAForecastFromPersistedHistory() async throws {
        let store = try makeStore()
        let now = Date()
        // Six hours of steady session burn, one sample every 30 minutes.
        for step in 0...12 {
            let at = now.addingTimeInterval(Double(step) * 1800 - 6 * 3600)
            try await store.record([
                UsageSample(provider: .claude, kind: .session, capturedAt: at,
                            percentUsed: Double(step) * 5, resetsAt: now.addingTimeInterval(3600)),
                UsageSample(provider: .claude, kind: .weekly, capturedAt: at,
                            percentUsed: Double(step) * 1.5, resetsAt: now.addingTimeInterval(4 * 86_400))
            ])
        }

        let engine = ForecastEngine(store: store)
        let forecasts = await engine.forecasts(
            claudeSessionResetsAt: now.addingTimeInterval(3600),
            claudeWeeklyResetsAt: now.addingTimeInterval(4 * 86_400),
            cursorResetsAt: nil,
            now: now
        )

        let session = try XCTUnwrap(forecasts.claudeSession)
        // 60 points over 6 hours = 10 %/hr.
        XCTAssertEqual(session.burnRatePerHour, 10, accuracy: 0.2)
        XCTAssertFalse(session.label.isEmpty)
        XCTAssertNil(forecasts.cursorCycle, "no Cursor history, so nothing to project")
        XCTAssertFalse(forecasts.anomalyFiring)
    }

    /// A cold store must produce nothing at all — never a zeroed-out forecast
    /// that looks like a real reading of "you're using nothing".
    func testEmptyHistoryProducesNoForecasts() async throws {
        let engine = ForecastEngine(store: try makeStore())
        let forecasts = await engine.forecasts(
            claudeSessionResetsAt: Date().addingTimeInterval(3600),
            claudeWeeklyResetsAt: Date().addingTimeInterval(86_400),
            cursorResetsAt: Date().addingTimeInterval(86_400)
        )
        XCTAssertTrue(forecasts.isEmpty)
        XCTAssertFalse(forecasts.anomalyFiring)
    }

    /// No store at all (a read-only disk, a corrupt file) degrades to silence,
    /// not a crash — forecasting is a feature, the menu bar is the product.
    func testMissingStoreDegradesToNothing() async {
        let engine = ForecastEngine(store: nil)
        let forecasts = await engine.forecasts(
            claudeSessionResetsAt: Date(),
            claudeWeeklyResetsAt: Date(),
            cursorResetsAt: Date()
        )
        XCTAssertEqual(forecasts, .none)
    }

    /// The detector's counter has to survive across polls, or it could only
    /// ever fire instantly and flap — which is the behaviour it exists to stop.
    func testAnomalyStateCarriesAcrossCalls() async throws {
        let store = try makeStore()
        let now = Date()

        // A week of calm windows (~5 %/hr), each ended by a reset.
        var at = now.addingTimeInterval(-6 * 86_400)
        for _ in 0..<6 {
            try await store.record([UsageSample(provider: .claude, kind: .session, capturedAt: at,
                                                percentUsed: 2, resetsAt: nil)])
            at = at.addingTimeInterval(4 * 3600)
            try await store.record([UsageSample(provider: .claude, kind: .session, capturedAt: at,
                                                percentUsed: 22, resetsAt: nil)])
            at = at.addingTimeInterval(2 * 3600)
        }
        // Then a runaway: 60 points in the last 20 minutes.
        try await store.record([UsageSample(provider: .claude, kind: .session,
                                            capturedAt: now.addingTimeInterval(-1200),
                                            percentUsed: 1, resetsAt: nil)])
        try await store.record([UsageSample(provider: .claude, kind: .session,
                                            capturedAt: now, percentUsed: 61, resetsAt: nil)])

        let engine = ForecastEngine(store: store)
        var firing: [Bool] = []
        for _ in 0..<3 {
            let forecasts = await engine.forecasts(
                claudeSessionResetsAt: now.addingTimeInterval(3600),
                claudeWeeklyResetsAt: nil, cursorResetsAt: nil, now: now
            )
            firing.append(forecasts.anomalyFiring)
        }
        XCTAssertEqual(firing, [false, false, true], "must take three sustained polls, then latch on")
    }

    // MARK: - Daylight saving

    /// All the maths is absolute-time arithmetic; only formatting is local. The
    /// spring-forward is where those two visibly disagree — the wall clock jumps
    /// six hours while five actually elapse — so it's the sharpest test that the
    /// two layers are properly separated.
    func testSpringForwardInViennaKeepsElapsedTimeAbsolute() throws {
        var vienna = Calendar(identifier: .gregorian)
        vienna.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Vienna"))
        // EU DST begins on the last Sunday of March: 2026-03-29, 02:00 → 03:00.
        let start = try XCTUnwrap(
            vienna.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 1, minute: 0))
        )
        let reset = start.addingTimeInterval(5 * 3600)

        // Five hours elapsed, regardless of what the clock on the wall did.
        XCTAssertEqual(ResetText.countdown(for: reset, now: start), "Resets in 5 hr")

        let points = [
            SeriesPoint(at: start, percentUsed: 0),
            SeriesPoint(at: reset, percentUsed: 50)
        ]
        XCTAssertEqual(try XCTUnwrap(BurnRate.windowLong(points)), 10, accuracy: 0.0001)

        // But the local clock legitimately reads 07:00, not 06:00 — one hour
        // was skipped. Displaying 06:00 here would be the bug.
        let clock = try XCTUnwrap(
            ResetText.clock(for: reset, now: start, calendar: vienna, locale: Locale(identifier: "en_GB"))
        )
        XCTAssertTrue(clock.contains("07"), "expected 07:00 local after spring-forward, got \(clock)")
    }

    /// The same, in a negative-offset zone, where the transition falls on a
    /// different date entirely.
    func testSpringForwardInLosAngelesKeepsElapsedTimeAbsolute() throws {
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        // US DST begins on the second Sunday of March: 2026-03-08, 02:00 → 03:00.
        let start = try XCTUnwrap(
            pacific.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 1, minute: 0))
        )
        let reset = start.addingTimeInterval(5 * 3600)

        XCTAssertEqual(ResetText.countdown(for: reset, now: start), "Resets in 5 hr")

        let points = [
            SeriesPoint(at: start, percentUsed: 10),
            SeriesPoint(at: reset, percentUsed: 60)
        ]
        XCTAssertEqual(try XCTUnwrap(BurnRate.windowLong(points)), 10, accuracy: 0.0001)

        let clock = try XCTUnwrap(
            ResetText.clock(for: reset, now: start, calendar: pacific, locale: Locale(identifier: "en_GB"))
        )
        XCTAssertTrue(clock.contains("07"), "expected 07:00 local after spring-forward, got \(clock)")
    }

    /// Autumn's repeated hour is the mirror image: the wall clock advances four
    /// hours while five elapse.
    func testFallBackInViennaKeepsElapsedTimeAbsolute() throws {
        var vienna = Calendar(identifier: .gregorian)
        vienna.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Vienna"))
        // EU DST ends on the last Sunday of October: 2026-10-25, 03:00 → 02:00.
        let start = try XCTUnwrap(
            vienna.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 1, minute: 0))
        )
        let reset = start.addingTimeInterval(5 * 3600)

        XCTAssertEqual(ResetText.countdown(for: reset, now: start), "Resets in 5 hr")

        let points = [
            SeriesPoint(at: start, percentUsed: 0),
            SeriesPoint(at: reset, percentUsed: 25)
        ]
        XCTAssertEqual(try XCTUnwrap(BurnRate.windowLong(points)), 5, accuracy: 0.0001)

        let clock = try XCTUnwrap(
            ResetText.clock(for: reset, now: start, calendar: vienna, locale: Locale(identifier: "en_GB"))
        )
        XCTAssertTrue(clock.contains("05"), "expected 05:00 local after fall-back, got \(clock)")
    }
}
