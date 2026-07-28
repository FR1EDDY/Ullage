import Foundation

/// How much the forecast should be trusted. Attached to **every** surfaced
/// number — the rule this whole layer is built on is that the UI never shows a
/// bare figure without saying how sure it is.
enum ForecastConfidence: Equatable, Sendable {
    case high
    case medium
    case low

    /// - high: enough samples *and* enough completed windows to have seen a
    ///   pattern rather than a moment.
    /// - low: fewer than five completed windows, so the percentile baseline has
    ///   fallen back to the observed maximum and is really just "the worst thing
    ///   that's happened so far".
    /// - medium: everything in between.
    static func from(sampleCount: Int, completedWindows: Int) -> ForecastConfidence {
        if completedWindows < minimumWindowsForBaseline { return .low }
        if sampleCount >= 20 && completedWindows >= minimumWindowsForBaseline { return .high }
        return .medium
    }

    /// Below this many completed windows a percentile is not meaningfully
    /// different from the maximum, so we say so instead of pretending.
    static let minimumWindowsForBaseline = 5

    /// The qualifier shown beside a forecast. `nil` for `.high`, where the
    /// absence of a hedge is itself the signal — a chip on every line would be
    /// noise, and the rule this serves is that a *shaky* number must never read
    /// as a certain one.
    var chip: String? {
        switch self {
        case .high: return nil
        case .medium: return "estimate"
        case .low: return "rough estimate"
        }
    }

    /// Explains *why* it's hedged, for the row's tooltip. "early estimate" read
    /// as "ignore this number" without saying what would make it better.
    var explanation: String {
        switch self {
        case .high: return "Based on several days of your usage."
        case .medium: return "Based on a few completed windows — it sharpens with more."
        case .low: return "Based on only a few hours of history so far. It sharpens over the first few days."
        }
    }
}

/// A forecast as the UI shows it: the finding, the working behind it, and how
/// much to trust it.
struct ForecastLine: Equatable, Sendable {
    /// The consequence, in plain language. This is the line the user reads.
    let text: String
    /// The mechanism — rate, projection, basis — shown on hover. Kept out of
    /// the line itself so the finding isn't competing with its own arithmetic.
    let detail: String
    let confidence: ForecastConfidence
    /// Set when the anomaly detector is firing, so the row can shift accent
    /// without a separate banner.
    var isAlarming: Bool = false
    /// True for the "still gathering history" line, which is not a forecast at
    /// all. It exists so a fresh install shows the same card shape as an
    /// established one, and so the absence of a projection reads as *not yet*
    /// rather than *not a feature*. Rendered without a confidence chip: there
    /// is no claim here to qualify.
    var isPlaceholder: Bool = false

    /// Shown for a connected provider with no history behind it yet. Every
    /// forecast in this app needs several completed windows before it means
    /// anything, which is hours on a new machine.
    static let gatheringHistory = ForecastLine(
        text: "Learning your usage — forecast in a few hours",
        detail: "Forecasts need a few completed windows before they mean anything. Nothing to do; this fills in on its own.",
        confidence: .low,
        isPlaceholder: true
    )

    var tooltip: String {
        isAlarming
            ? "\(detail)\n\nThis is far faster than your usual pace — check for a runaway task."
            : detail
    }
}

/// Where the window currently in progress is heading.
struct SessionForecast: Equatable, Sendable {
    /// Percent-points per hour, window-long. Kept for the tooltip: it explains
    /// the forecast, but it is not itself the finding.
    let burnRatePerHour: Double
    /// When the window would hit 100% at the current rate, or `nil` if it never
    /// does before the window resets anyway.
    let exhaustionAt: Date?
    /// True when the limit resets before the burn rate could exhaust it.
    let isSafeUntilReset: Bool
    /// Where the window lands at reset, when it lands below the cap. The
    /// concrete, checkable version of "you're fine".
    let projectedPercentAtReset: Double?
    /// How far ahead of the reset the limit runs out. The whole point of the
    /// forecast in the case that matters.
    let marginBeforeReset: TimeInterval?
    let confidence: ForecastConfidence

    /// States a **consequence**, not a mechanism.
    ///
    /// This used to read "25%/hr · ~2.4h left", which is accurate and nearly
    /// useless: percent-points per hour of an opaque quota isn't a unit anyone
    /// thinks in, and "2.4h left" sitting next to "resets in 3 hr 19 min" made
    /// the reader do the subtraction that *is* the insight. Now it does the
    /// subtraction and reports what falls out of it.
    var label: String {
        if !isSafeUntilReset {
            if let marginBeforeReset, marginBeforeReset > 60 {
                return "On pace to run out ~\(Self.formatDuration(marginBeforeReset)) early"
            }
            return "On pace to run out just before reset"
        }
        if let projectedPercentAtReset {
            return "On pace to finish around \(Int(projectedPercentAtReset.rounded()))%"
        }
        return "On pace to stay under the limit"
    }

    /// The mechanism, moved to a tooltip where it informs without competing.
    var detail: String {
        "Burning \(Self.formatRate(burnRatePerHour)) of this window. \(confidence.explanation)"
    }

    static func formatRate(_ rate: Double) -> String {
        rate < 10 ? String(format: "%.1f%%/hr", rate) : String(format: "%.0f%%/hr", rate)
    }

    /// Deliberately coarse — a forecast printed to the minute claims a
    /// precision the underlying rate does not have.
    static func formatDuration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours >= 5 || remainder == 0 { return "\(hours) hr" }
        return "\(hours) hr \(remainder) min"
    }
}

enum Forecast {
    /// Projects the current window forward at its own average rate.
    ///
    /// ```
    /// hoursRemaining = (100 − percentUsed) / burnRate
    /// exhaustionAt   = now + hoursRemaining
    /// ```
    ///
    /// The exhaustion time is only surfaced when it lands **before** the reset.
    /// Otherwise the honest answer is that the window resets first, and the
    /// forecast says so rather than quoting a time that will never arrive.
    ///
    /// Returns `nil` when there is nothing truthful to say: no samples, no
    /// measurable rate, or a window already at its cap.
    static func session(
        points: [SeriesPoint],
        resetsAt: Date?,
        now: Date = Date()
    ) -> SessionForecast? {
        let segment = BurnRate.currentSegment(points)
        guard let latest = segment.last else { return nil }
        guard let rate = BurnRate.rate(over: segment), rate > 0 else { return nil }

        let confidence = ForecastConfidence.from(
            sampleCount: points.count,
            completedWindows: BurnRate.completedSegments(points).count
        )

        // A reset date already in the past means the window has turned over and
        // we simply haven't observed it yet — treat it as no boundary at all
        // rather than as a boundary we've already crossed.
        let boundary = resetsAt.flatMap { $0 > now ? $0 : nil }

        let remainingPercent = 100 - latest.percentUsed
        guard remainingPercent > 0 else {
            // Already at the cap. There's no time-to-exhaustion left to
            // forecast, and claiming "safe until reset" would be a lie.
            return SessionForecast(
                burnRatePerHour: rate,
                exhaustionAt: now,
                isSafeUntilReset: false,
                projectedPercentAtReset: nil,
                marginBeforeReset: boundary.map { $0.timeIntervalSince(now) },
                confidence: confidence
            )
        }

        let hoursRemaining = remainingPercent / rate
        let exhaustionAt = now.addingTimeInterval(hoursRemaining * 3600)
        let safe = boundary.map { exhaustionAt >= $0 } ?? false

        // Bound separately rather than force-unwrapped inside a ternary: the
        // unwrap was safe only because of the condition beside it, which is the
        // kind of coupling a later edit quietly breaks.
        let projectedAtReset: Double? = safe
            ? boundary.map { min(100, latest.percentUsed + rate * ($0.timeIntervalSince(now) / 3600)) }
            : nil

        return SessionForecast(
            burnRatePerHour: rate,
            exhaustionAt: safe ? nil : exhaustionAt,
            isSafeUntilReset: safe,
            // Where it lands at reset — the concrete form of "you're fine".
            projectedPercentAtReset: projectedAtReset,
            // How much earlier than the reset it runs dry — the finding the
            // reader would otherwise have to compute by hand.
            marginBeforeReset: safe ? nil : boundary.map { $0.timeIntervalSince(exhaustionAt) },
            confidence: confidence
        )
    }
}
