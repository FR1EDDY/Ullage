import Foundation

/// Detects a runaway session — an agent stuck in a loop, a job that should have
/// finished an hour ago — by comparing the last half-hour's burn rate against
/// what this account normally does.
///
/// Two design choices carry the whole thing:
///   - the baseline is a **median**, not a mean, so the runaway session can't
///     inflate the very number it's being measured against;
///   - it must stay high for **three consecutive polls** before firing, which
///     is what stops a single burst of legitimate work from flapping the alert
///     on and off. An alert that cries wolf gets ignored, and then it may as
///     well not exist.
struct AnomalyState: Equatable, Sendable {
    /// How many polls in a row have exceeded the threshold.
    var consecutiveHighPolls: Int = 0
    /// Whether the alert is currently showing.
    var isFiring: Bool = false

    static let idle = AnomalyState()
}

enum AnomalyDetector {
    /// How much faster than normal counts as abnormal.
    static let multiplier: Double = 3
    /// Consecutive breaches required before the alert appears.
    static let sustainedPolls = 3
    /// How far back to gather the baseline.
    static let baselineLookback: TimeInterval = 7 * 24 * 60 * 60

    /// Advances the detector by one poll. Pure: state in, state out, so a whole
    /// sequence of polls can be replayed in a test.
    ///
    /// Clearing is deliberately immediate while firing needs three polls: being
    /// slow to raise an alarm is caution, but being slow to withdraw one is
    /// just being wrong for longer.
    static func advance(
        state: AnomalyState,
        shortHorizonRate: Double?,
        baseline: Double?
    ) -> AnomalyState {
        guard let shortHorizonRate,
              let baseline,
              baseline > 0
        else {
            // Not enough history to have a normal, so nothing can be abnormal.
            return .idle
        }

        let threshold = baseline * multiplier
        guard shortHorizonRate > threshold else {
            return .idle
        }

        let count = state.consecutiveHighPolls + 1
        return AnomalyState(
            consecutiveHighPolls: count,
            isFiring: count >= sustainedPolls
        )
    }

    /// The median rate across completed, *active* windows in the trailing week.
    /// Idle windows are excluded: a median dragged toward zero by days you
    /// didn't work would make ordinary work look like a runaway.
    static func baseline(points: [SeriesPoint], now: Date = Date()) -> Double? {
        let cutoff = now.addingTimeInterval(-baselineLookback)
        let recent = points.filter { $0.at >= cutoff }
        let rates = BurnRate.completedWindowRates(recent, activeOnly: true)
        guard rates.count >= 2 else { return nil }
        return Percentile.median(of: rates)
    }
}
