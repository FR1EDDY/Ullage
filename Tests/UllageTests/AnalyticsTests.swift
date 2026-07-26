import XCTest
@testable import Ullage

/// Synthetic series only — every scenario is a literal list of numbers, which
/// is the point of keeping this layer free of I/O.
final class AnalyticsTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_784_000_000)

    /// `at` is hours from the origin.
    private func point(_ hours: Double, _ percent: Double) -> SeriesPoint {
        SeriesPoint(at: origin.addingTimeInterval(hours * 3600), percentUsed: percent)
    }

    private func time(_ hours: Double) -> Date {
        origin.addingTimeInterval(hours * 3600)
    }

    // MARK: - Percentile

    /// Linear interpolation between order statistics (R-7 / NumPy default),
    /// not nearest-rank. Pinned against values NumPy produces.
    func testPercentileUsesLinearInterpolation() throws {
        let values: [Double] = [1, 2, 3, 4]
        XCTAssertEqual(try XCTUnwrap(Percentile.p(0.0, of: values)), 1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(Percentile.p(0.5, of: values)), 2.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(Percentile.p(1.0, of: values)), 4, accuracy: 0.0001)
        // rank = 3 × 0.9 = 2.7 → 3 + 0.7×(4−3) = 3.7
        XCTAssertEqual(try XCTUnwrap(Percentile.p(0.9, of: values)), 3.7, accuracy: 0.0001)
    }

    /// The reason a percentile beats a mean here: consumption is bursty, and
    /// P90 must track the spikes that actually exhaust a limit rather than the
    /// idle days that dominate the average.
    func testBurstyDataMakesP90FarExceedTheMean() throws {
        let bursty: [Double] = [0, 0, 0, 0, 0, 0, 0, 0, 20, 24]
        let mean = bursty.reduce(0, +) / Double(bursty.count)
        let p90 = try XCTUnwrap(Percentile.p(0.9, of: bursty))
        XCTAssertEqual(mean, 4.4, accuracy: 0.0001)
        XCTAssertGreaterThan(p90, mean * 4, "a mean would under-predict this pattern badly")
    }

    func testPercentileDegenerateInput() {
        XCTAssertNil(Percentile.p(0.9, of: []))
        XCTAssertEqual(Percentile.p(0.9, of: [7]), 7)
        XCTAssertEqual(Percentile.p(0.9, of: [5, 5, 5]), 5)
        XCTAssertNil(Percentile.median(of: []))
    }

    // MARK: - Burn rate

    func testSteadyBurnGivesAStableRate() throws {
        // 10% over 5 hours = 2%/hr.
        let points = [point(0, 0), point(1, 2), point(3, 6), point(5, 10)]
        XCTAssertEqual(try XCTUnwrap(BurnRate.windowLong(points)), 2, accuracy: 0.0001)
    }

    /// The single most important guard: measured across a reset the delta is
    /// negative, and a naive rate would forecast a limit that heals itself.
    func testMidWindowResetSplitsTheSeriesAndNeverGoesNegative() throws {
        let points = [point(0, 40), point(1, 70), point(2, 95), point(3, 4), point(4, 12)]

        let segments = BurnRate.segments(points)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].map(\.percentUsed), [40, 70, 95])
        XCTAssertEqual(segments[1].map(\.percentUsed), [4, 12])

        // The live rate is measured only inside the post-reset segment.
        let rate = try XCTUnwrap(BurnRate.windowLong(points))
        XCTAssertEqual(rate, 8, accuracy: 0.0001)
        XCTAssertGreaterThan(rate, 0)
    }

    func testBurnRateGuardsAgainstDegenerateInput() {
        XCTAssertNil(BurnRate.windowLong([]), "no samples")
        XCTAssertNil(BurnRate.windowLong([point(0, 10)]), "one sample can't imply a rate")

        // Two samples in the same instant would divide by ~zero.
        let simultaneous = [
            SeriesPoint(at: origin, percentUsed: 10),
            SeriesPoint(at: origin.addingTimeInterval(0.2), percentUsed: 40)
        ]
        XCTAssertNil(BurnRate.windowLong(simultaneous))

        // Flat series: a real, honest zero — not nil.
        XCTAssertEqual(BurnRate.windowLong([point(0, 5), point(4, 5)]), 0)
    }

    func testShortHorizonOnlyLooksAtTheTrailingWindow() throws {
        // Slow for hours, then a burst in the last half hour.
        let points = [point(0, 0), point(3, 6), point(3.5, 8), point(4, 30)]
        let now = time(4)

        let long = try XCTUnwrap(BurnRate.windowLong(points))
        let short = try XCTUnwrap(BurnRate.shortHorizon(points, now: now))
        XCTAssertEqual(long, 7.5, accuracy: 0.0001)
        XCTAssertEqual(short, 44, accuracy: 0.0001)
        XCTAssertGreaterThan(short, long * 5, "the burst must be visible in the short rate")
    }

    // MARK: - Session forecast

    func testSteadyBurnProducesASaneExhaustionTime() throws {
        // 20% used, 5%/hr → 16 hours to exhaustion, but reset is in 2 hours.
        let points = [point(0, 0), point(4, 20)]
        let forecast = try XCTUnwrap(
            Forecast.session(points: points, resetsAt: time(6), now: time(4))
        )
        XCTAssertEqual(forecast.burnRatePerHour, 5, accuracy: 0.0001)
        XCTAssertTrue(forecast.isSafeUntilReset)
        XCTAssertNil(forecast.exhaustionAt)
        // "You're fine" stated concretely: 20% now, 5%/hr, 2 hours to reset → 30%.
        XCTAssertEqual(try XCTUnwrap(forecast.projectedPercentAtReset), 30, accuracy: 0.0001)
        XCTAssertEqual(forecast.label, "On pace to finish around 30%")
    }

    /// "Safe until reset" is a first-class answer, not a fallback — this is the
    /// case where telling the user they're fine is the whole value.
    func testExhaustionIsOnlySurfacedWhenItBeatsTheReset() throws {
        // 60% used at 20%/hr → 2 hours left; reset is 5 hours out.
        let points = [point(0, 0), point(3, 60)]
        let forecast = try XCTUnwrap(
            Forecast.session(points: points, resetsAt: time(8), now: time(3))
        )
        XCTAssertFalse(forecast.isSafeUntilReset)
        let exhaustionAt = try XCTUnwrap(forecast.exhaustionAt)
        XCTAssertEqual(exhaustionAt.timeIntervalSince(time(3)) / 3600, 2, accuracy: 0.01)
        // The finding the reader would otherwise have to work out by hand:
        // exhaustion at +2h, reset at +5h, so it runs dry 3 hours early.
        XCTAssertEqual(try XCTUnwrap(forecast.marginBeforeReset) / 3600, 3, accuracy: 0.01)
        XCTAssertEqual(forecast.label, "On pace to run out ~3 hr early")
    }

    /// Cold start: one sample, no rate, nothing to say — and crucially no
    /// fabricated number.
    func testColdStartProducesNoForecast() {
        XCTAssertNil(Forecast.session(points: [], resetsAt: time(5), now: origin))
        XCTAssertNil(Forecast.session(points: [point(0, 12)], resetsAt: time(5), now: origin))
        // Flat usage: a rate of zero can't reach a limit, so there's no forecast.
        XCTAssertNil(Forecast.session(points: [point(0, 12), point(3, 12)], resetsAt: time(5), now: time(3)))
    }

    /// A `resetsAt` in the past means the window already turned over and we
    /// haven't observed it yet — it must not be treated as a boundary we've
    /// crossed, which would report "safe" forever.
    func testStaleResetDateIsIgnored() throws {
        let points = [point(0, 0), point(3, 60)]
        let forecast = try XCTUnwrap(
            Forecast.session(points: points, resetsAt: time(-2), now: time(3))
        )
        XCTAssertFalse(forecast.isSafeUntilReset)
        XCTAssertNotNil(forecast.exhaustionAt)
    }

    func testForecastCarriesConfidence() throws {
        let sparse = [point(0, 0), point(2, 10)]
        let forecast = try XCTUnwrap(Forecast.session(points: sparse, resetsAt: time(9), now: time(2)))
        XCTAssertEqual(forecast.confidence, .low, "two samples and no completed window is a cold start")
    }

    func testConfidenceThresholds() {
        XCTAssertEqual(ForecastConfidence.from(sampleCount: 40, completedWindows: 6), .high)
        XCTAssertEqual(ForecastConfidence.from(sampleCount: 8, completedWindows: 6), .medium)
        XCTAssertEqual(ForecastConfidence.from(sampleCount: 40, completedWindows: 2), .low)
        XCTAssertEqual(ForecastConfidence.from(sampleCount: 1, completedWindows: 0), .low)
    }

    // MARK: - Weekly projection

    /// Six completed sessions, each costing the weekly budget ~3 points, with
    /// plenty of reset left — the under-utilization branch.
    func testIdleWeekReportsUnusedWindows() throws {
        var session: [SeriesPoint] = []
        var weekly: [SeriesPoint] = []
        for index in 0..<6 {
            let start = Double(index) * 6
            session.append(point(start, 0))
            session.append(point(start + 4, 80))
            weekly.append(point(start, Double(index) * 3))
            weekly.append(point(start + 4, Double(index) * 3 + 3))
        }
        // The window in progress, so the last session segment is "completed".
        session.append(point(36, 5))
        weekly.append(point(36, 18))

        let now = time(36)
        let projection = try XCTUnwrap(
            WeeklyProjection.weekly(
                sessionPoints: session,
                weeklyPoints: weekly,
                resetsAt: now.addingTimeInterval(3 * 86_400),
                now: now
            )
        )

        XCTAssertNil(projection.crossesAt, "18% with ~3 points per session shouldn't reach 100")
        let unused = try XCTUnwrap(projection.unusedWindows)
        XCTAssertGreaterThan(unused, 0)
        XCTAssertTrue(projection.label.contains("more heavy session"), projection.label)
        // Six completed windows clears the baseline bar, but 13 weekly samples
        // is under the 20-sample bar — so "medium", not "high". Exactly the
        // boundary the confidence rule exists to express: the pattern is there,
        // the sampling behind it isn't dense yet.
        XCTAssertEqual(projection.confidence, .medium)
    }

    /// The other branch: already high, with heavy sessions and time to burn.
    func testHeavyUseProjectsACrossingTime() throws {
        var session: [SeriesPoint] = []
        var weekly: [SeriesPoint] = []
        for index in 0..<6 {
            let start = Double(index) * 6
            session.append(point(start, 0))
            session.append(point(start + 4, 90))
            weekly.append(point(start, Double(index) * 12))
            weekly.append(point(start + 4, Double(index) * 12 + 12))
        }
        session.append(point(36, 10))
        weekly.append(point(36, 72))

        let now = time(36)
        let projection = try XCTUnwrap(
            WeeklyProjection.weekly(
                sessionPoints: session,
                weeklyPoints: weekly,
                resetsAt: now.addingTimeInterval(3 * 86_400),
                now: now
            )
        )

        let crossesAt = try XCTUnwrap(projection.crossesAt)
        XCTAssertGreaterThan(crossesAt, now)
        XCTAssertNil(projection.unusedWindows)
        XCTAssertTrue(projection.label.contains("run out"), projection.label)
    }

    /// Headroom you have no time to spend isn't headroom.
    func testUnusedWindowsAreCappedByTimeRemaining() throws {
        var session: [SeriesPoint] = []
        var weekly: [SeriesPoint] = []
        for index in 0..<6 {
            let start = Double(index) * 6
            session.append(point(start, 0))
            session.append(point(start + 4, 80))
            weekly.append(point(start, Double(index)))
            weekly.append(point(start + 4, Double(index) + 1))
        }
        session.append(point(36, 5))
        weekly.append(point(36, 6))

        let now = time(36)
        // Only 6 hours left → at most one more 5-hour window fits.
        let projection = try XCTUnwrap(
            WeeklyProjection.weekly(
                sessionPoints: session,
                weeklyPoints: weekly,
                resetsAt: now.addingTimeInterval(6 * 3600),
                now: now
            )
        )
        XCTAssertEqual(projection.unusedWindows, 1)
    }

    func testWeeklyProjectionNeedsAFutureResetAndRealUsage() {
        let session = [point(0, 0), point(4, 80), point(6, 5)]
        let weekly = [point(0, 10), point(4, 10), point(6, 10)]
        let now = time(6)
        XCTAssertNil(WeeklyProjection.weekly(sessionPoints: session, weeklyPoints: weekly, resetsAt: nil, now: now))
        XCTAssertNil(WeeklyProjection.weekly(sessionPoints: session, weeklyPoints: weekly, resetsAt: time(1), now: now))
        // Weekly never moved, so there is no per-session cost to project.
        XCTAssertNil(
            WeeklyProjection.weekly(
                sessionPoints: session, weeklyPoints: weekly,
                resetsAt: now.addingTimeInterval(86_400), now: now
            )
        )
    }

    /// Day one: no session has completed yet, so there are no per-session costs
    /// to build a percentile from. Rather than stay silent for days — exactly
    /// when someone is deciding whether this app earns its place — it falls back
    /// to projecting the weekly series at its own rate, marked low confidence.
    func testWeeklyFallsBackToARateProjectionBeforeAnySessionCompletes() throws {
        // One window still in progress: no completed segments at all.
        let session = [point(0, 0), point(2, 20), point(4, 40)]
        let weekly = [point(0, 2), point(2, 6), point(4, 10)]
        let now = time(4)

        XCTAssertTrue(
            WeeklyProjection.sessionDeltas(sessionPoints: session, weeklyPoints: weekly, now: now).isEmpty,
            "precondition: nothing has completed yet"
        )

        let projection = try XCTUnwrap(
            WeeklyProjection.weekly(
                sessionPoints: session,
                weeklyPoints: weekly,
                resetsAt: now.addingTimeInterval(10 * 3600),
                now: now
            )
        )
        // 2%/hr for 10 more hours from 10% → ~30%.
        XCTAssertEqual(projection.projectedPercent, 30, accuracy: 0.5)
        XCTAssertEqual(projection.confidence, .low, "a rate projection is the coarse version, and says so")
        XCTAssertNil(projection.unusedWindows, "window counting needs completed windows")
        XCTAssertEqual(projection.label, "On pace to finish around 30%")
    }

    /// A session that straddles a weekly reset tells us nothing about its cost
    /// and must be discarded, not counted as a negative.
    func testSessionSpanningAWeeklyResetIsDiscarded() {
        let session = [point(0, 0), point(4, 80), point(6, 5), point(8, 40)]
        let weekly = [point(0, 95), point(4, 2), point(6, 3), point(8, 5)]
        let deltas = WeeklyProjection.sessionDeltas(sessionPoints: session, weeklyPoints: weekly, now: time(8))
        XCTAssertTrue(deltas.allSatisfy { $0 >= 0 }, "no negative session cost: \(deltas)")
    }

    // MARK: - Series sampling

    func testSeriesSamplingInterpolatesAndClamps() throws {
        let points = [point(0, 10), point(2, 30)]
        XCTAssertEqual(try XCTUnwrap(SeriesSampling.value(of: points, at: time(1))), 20, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(SeriesSampling.value(of: points, at: time(-5))), 10, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(SeriesSampling.value(of: points, at: time(9))), 30, accuracy: 0.0001)
        XCTAssertNil(SeriesSampling.value(of: [], at: time(1)))
    }

    // MARK: - Anomaly detection

    /// Must fire only after three sustained breaches, and clear immediately.
    func testAnomalyRequiresThreeSustainedPollsAndClearsAtOnce() {
        var state = AnomalyState.idle
        let baseline = 5.0            // threshold = 15
        let hot = 40.0

        state = AnomalyDetector.advance(state: state, shortHorizonRate: hot, baseline: baseline)
        XCTAssertFalse(state.isFiring, "one breach is a burst, not an anomaly")
        state = AnomalyDetector.advance(state: state, shortHorizonRate: hot, baseline: baseline)
        XCTAssertFalse(state.isFiring)
        state = AnomalyDetector.advance(state: state, shortHorizonRate: hot, baseline: baseline)
        XCTAssertTrue(state.isFiring, "three sustained breaches should fire")

        state = AnomalyDetector.advance(state: state, shortHorizonRate: 6, baseline: baseline)
        XCTAssertFalse(state.isFiring, "clearing is immediate — a stale alarm is worse than a late one")
        XCTAssertEqual(state.consecutiveHighPolls, 0)
    }

    func testAnomalyDoesNotFireWithoutABaseline() {
        var state = AnomalyState.idle
        for _ in 0..<5 {
            state = AnomalyDetector.advance(state: state, shortHorizonRate: 500, baseline: nil)
        }
        XCTAssertFalse(state.isFiring, "no normal means nothing can be abnormal")

        for _ in 0..<5 {
            state = AnomalyDetector.advance(state: state, shortHorizonRate: nil, baseline: 5)
        }
        XCTAssertFalse(state.isFiring)
    }

    /// A median baseline can't be inflated by the very session it's measuring —
    /// a mean could, quietly raising the threshold to accommodate the anomaly.
    func testBaselineUsesMedianSoOneRunawayCannotPoisonIt() throws {
        let rates: [Double] = [4, 5, 6, 5, 200]
        let median = try XCTUnwrap(Percentile.median(of: rates))
        let mean = rates.reduce(0, +) / Double(rates.count)
        XCTAssertEqual(median, 5, accuracy: 0.0001)
        XCTAssertGreaterThan(mean, 40)
        // With the mean, a 40%/hr runaway wouldn't even reach the threshold.
        XCTAssertLessThan(median * AnomalyDetector.multiplier, 40)
        XCTAssertGreaterThan(mean * AnomalyDetector.multiplier, 40)
    }

    func testBaselineIgnoresIdleWindows() throws {
        // Three worked windows (rates 5, 10, 15) interleaved with two the user
        // opened and never touched. An idle window is only *visible* as its own
        // segment when it sits at a non-zero floor — a window that resets to 0
        // and stays there is indistinguishable from the next one starting, which
        // is a property of the data, not something to paper over.
        let points = [
            point(0, 0), point(2, 10),      // worked: 5 %/hr
            point(6, 3), point(8, 3),       // idle
            point(12, 1), point(14, 21),    // worked: 10 %/hr
            point(18, 2), point(20, 2),     // idle
            point(24, 1), point(26, 31),    // worked: 15 %/hr
            point(30, 1)                    // window in progress
        ]

        let activeRates = BurnRate.completedWindowRates(points, activeOnly: true)
        XCTAssertEqual(activeRates.sorted(), [5, 10, 15])

        let baseline = try XCTUnwrap(AnomalyDetector.baseline(points: points, now: time(30)))
        XCTAssertEqual(baseline, 10, accuracy: 0.0001)

        // Counting the idle windows would halve the baseline, and a halved
        // baseline means ordinary work starts tripping the anomaly alert.
        let withIdle = BurnRate.completedWindowRates(points, activeOnly: false)
        let pollutedBaseline = try XCTUnwrap(Percentile.median(of: withIdle))
        XCTAssertLessThan(pollutedBaseline, baseline)
    }

    // MARK: - No NaN, ever

    /// The acceptance criterion, swept across every degenerate shape at once.
    func testNoDegenerateInputProducesNaNOrNegativeOutput() {
        let cases: [[SeriesPoint]] = [
            [],
            [point(0, 0)],
            [point(0, 100), point(1, 100)],
            [point(0, 0), point(0, 50)],                  // zero elapsed
            [point(0, 50), point(1, 0), point(2, 0)],     // reset then idle
            [point(0, 0), point(240, 100)]                // a huge gap
        ]
        for points in cases {
            if let rate = BurnRate.windowLong(points) {
                XCTAssertFalse(rate.isNaN, "NaN rate for \(points.count) points")
                XCTAssertGreaterThanOrEqual(rate, 0, "negative rate for \(points.count) points")
            }
            if let forecast = Forecast.session(points: points, resetsAt: time(300), now: time(240)) {
                XCTAssertFalse(forecast.burnRatePerHour.isNaN)
                XCTAssertGreaterThanOrEqual(forecast.burnRatePerHour, 0)
                XCTAssertFalse(forecast.label.contains("nan"))
            }
            if let projection = WeeklyProjection.cycle(points: points, resetsAt: time(400), now: time(240)) {
                XCTAssertFalse(projection.projectedPercent.isNaN)
                XCTAssertGreaterThanOrEqual(projection.projectedPercent, 0)
            }
        }
    }
}
