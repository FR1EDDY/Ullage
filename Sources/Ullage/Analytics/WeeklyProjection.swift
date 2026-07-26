import Foundation

/// Where a long window (Claude's 7 days, Cursor's month) is heading, and — just
/// as usefully — how much of it you're leaving on the table.
struct WindowProjection: Equatable, Sendable {
    let currentPercent: Double
    /// Where the window lands by its reset if the recent pattern continues.
    let projectedPercent: Double
    /// When it would cross 100%, if it does so before resetting.
    let crossesAt: Date?
    /// Spare capacity expressed in whole 5-hour windows. `nil` for projections
    /// that aren't window-based (Cursor has no sub-windows to count).
    let unusedWindows: Int?
    let confidence: ForecastConfidence

    /// The under-utilization branch is not a consolation prize for failing to
    /// predict trouble — it's the answer most of the time, and no competitor
    /// shows it. "Room for 11 more heavy sessions" is genuinely reassuring in a
    /// way that "18% used" is not.
    ///
    /// Phrased as a consequence rather than a rate, for the same reason as
    /// `SessionForecast.label`: the reader wants to know what happens, not what
    /// the arithmetic was.
    var label: String {
        if let crossesAt {
            return "On pace to run out ~\(Self.formatCrossing(crossesAt))"
        }
        if let unusedWindows {
            guard unusedWindows > 0 else { return "Little headroom left" }
            return "Room for ~\(unusedWindows) more heavy session\(unusedWindows == 1 ? "" : "s")"
        }
        return "On pace to finish around \(Int(projectedPercent.rounded()))%"
    }

    var detail: String {
        "Projected \(Int(projectedPercent.rounded()))% by reset, from \(Int(currentPercent.rounded()))% now. \(confidence.explanation)"
    }

    private static func formatCrossing(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(
            date.timeIntervalSinceNow < 6 * 24 * 3600 ? "EEEjmm" : "MMMd"
        )
        return formatter.string(from: date)
    }
}

/// Reading a series at an arbitrary instant.
enum SeriesSampling {
    /// The value at `time`, linearly interpolated between the two bracketing
    /// samples and clamped to the endpoints outside the series.
    ///
    /// Interpolation rather than nearest-neighbour because these percentages
    /// are cumulative counters: between two polls the true value lies *between*
    /// the two readings, never outside them, so interpolating can't invent a
    /// value the counter didn't pass through.
    static func value(of points: [SeriesPoint], at time: Date) -> Double? {
        guard !points.isEmpty else { return nil }
        let ordered = points.sorted { $0.at < $1.at }
        if time <= ordered[0].at { return ordered[0].percentUsed }
        if let last = ordered.last, time >= last.at { return last.percentUsed }

        for index in 1..<ordered.count {
            let previous = ordered[index - 1]
            let next = ordered[index]
            guard time <= next.at else { continue }
            let span = next.at.timeIntervalSince(previous.at)
            guard span > 0 else { return next.percentUsed }
            let weight = time.timeIntervalSince(previous.at) / span
            return previous.percentUsed + weight * (next.percentUsed - previous.percentUsed)
        }
        return ordered.last?.percentUsed
    }
}

enum WeeklyProjection {
    /// Claude's 5-hour session window, the unit headroom is counted in.
    static let sessionWindow: TimeInterval = 5 * 60 * 60
    /// How far back to look for completed sessions. Slightly wider than the
    /// 7-day window it feeds so a session straddling the boundary still counts.
    static let lookback: TimeInterval = 8 * 24 * 60 * 60

    /// The weekly projection, built to work from **percentages alone**.
    ///
    /// We don't know the absolute token quota behind either limit, so instead of
    /// guessing at one we measure the weekly window's own movement: for each
    /// completed session, how much did the weekly percentage rise across it?
    /// That gives "what one heavy session costs the weekly budget" in the only
    /// unit we actually observe.
    ///
    /// ```
    /// weeklyDeltaᵢ    = weekly%(session end) − weekly%(session start)
    /// p90Delta        = P90(weeklyDeltas)          ← bursty, so a percentile
    /// windowsRemaining= floor(timeUntilReset / 5h)
    /// projected       = currentWeekly + windowsRemaining × p90Delta
    /// ```
    static func weekly(
        sessionPoints: [SeriesPoint],
        weeklyPoints: [SeriesPoint],
        resetsAt: Date?,
        now: Date = Date()
    ) -> WindowProjection? {
        guard let current = weeklyPoints.sorted(by: { $0.at < $1.at }).last?.percentUsed else { return nil }
        guard let resetsAt, resetsAt > now else { return nil }

        let deltas = sessionDeltas(sessionPoints: sessionPoints, weeklyPoints: weeklyPoints, now: now)
        let completedWindows = deltas.count

        // Below five completed windows a percentile is indistinguishable from
        // the maximum, so we use the maximum and say the confidence is low
        // rather than dressing it up as a percentile.
        let perWindowCost: Double?
        if completedWindows >= ForecastConfidence.minimumWindowsForBaseline {
            perWindowCost = Percentile.p(0.90, of: deltas)
        } else {
            perWindowCost = deltas.max()
        }

        // Before the first session has completed there are no deltas at all, and
        // the window-counting method has nothing to work with. Rather than stay
        // silent for days — which is exactly when someone is deciding whether
        // this app is worth keeping — fall back to projecting the weekly series
        // at its own observed rate, marked down to low confidence. Coarser, but
        // it says something true from the first hour.
        guard let perWindowCost, perWindowCost > 0 else {
            guard let fallback = cycle(points: weeklyPoints, resetsAt: resetsAt, now: now) else { return nil }
            return WindowProjection(
                currentPercent: fallback.currentPercent,
                projectedPercent: fallback.projectedPercent,
                crossesAt: fallback.crossesAt,
                unusedWindows: nil,
                confidence: .low
            )
        }

        let windowsRemaining = max(0, Int((resetsAt.timeIntervalSince(now) / sessionWindow).rounded(.down)))
        let projected = min(1000, current + Double(windowsRemaining) * perWindowCost)
        let confidence = ForecastConfidence.from(
            sampleCount: weeklyPoints.count,
            completedWindows: completedWindows
        )

        if projected >= 100 {
            let windowsNeeded = (100 - current) / perWindowCost
            let crossesAt = now.addingTimeInterval(windowsNeeded * sessionWindow)
            return WindowProjection(
                currentPercent: current,
                projectedPercent: projected,
                crossesAt: min(crossesAt, resetsAt),
                unusedWindows: nil,
                confidence: confidence
            )
        }

        // The inverse, and the more common answer: how many heavy sessions of
        // headroom are left. Capped by the windows that actually fit before the
        // reset — spare budget you have no time to spend isn't headroom.
        let affordable = Int(((100 - current) / perWindowCost).rounded(.down))
        return WindowProjection(
            currentPercent: current,
            projectedPercent: projected,
            crossesAt: nil,
            unusedWindows: min(affordable, windowsRemaining),
            confidence: confidence
        )
    }

    /// A cycle with no sub-windows to count — Cursor's month. Projects the
    /// observed rate forward to the reset instead of counting sessions.
    static func cycle(
        points: [SeriesPoint],
        resetsAt: Date?,
        now: Date = Date()
    ) -> WindowProjection? {
        let segment = BurnRate.currentSegment(points)
        guard let current = segment.last?.percentUsed else { return nil }
        guard let resetsAt, resetsAt > now else { return nil }
        guard let rate = BurnRate.rate(over: segment), rate > 0 else { return nil }

        let hoursRemaining = resetsAt.timeIntervalSince(now) / 3600
        let projected = min(1000, current + rate * hoursRemaining)
        let confidence = ForecastConfidence.from(
            sampleCount: points.count,
            // A monthly cycle has no completed sub-windows to count, so the
            // sample count alone decides — treated as meeting the window bar so
            // a long, well-sampled cycle isn't permanently stuck at "low".
            completedWindows: ForecastConfidence.minimumWindowsForBaseline
        )

        guard projected >= 100 else {
            return WindowProjection(
                currentPercent: current,
                projectedPercent: projected,
                crossesAt: nil,
                unusedWindows: nil,
                confidence: confidence
            )
        }
        let hoursNeeded = (100 - current) / rate
        return WindowProjection(
            currentPercent: current,
            projectedPercent: projected,
            crossesAt: min(now.addingTimeInterval(hoursNeeded * 3600), resetsAt),
            unusedWindows: nil,
            confidence: confidence
        )
    }

    /// What each completed session cost the weekly budget, over the lookback.
    static func sessionDeltas(
        sessionPoints: [SeriesPoint],
        weeklyPoints: [SeriesPoint],
        now: Date = Date()
    ) -> [Double] {
        let cutoff = now.addingTimeInterval(-lookback)
        return BurnRate.completedSegments(sessionPoints).compactMap { segment in
            guard let start = segment.first, let end = segment.last, end.at >= cutoff else { return nil }
            guard let weeklyStart = SeriesSampling.value(of: weeklyPoints, at: start.at),
                  let weeklyEnd = SeriesSampling.value(of: weeklyPoints, at: end.at)
            else { return nil }
            let delta = weeklyEnd - weeklyStart
            // A negative delta means the weekly window itself reset inside this
            // session; that session tells us nothing about its cost.
            return delta >= 0 ? delta : nil
        }
    }
}
