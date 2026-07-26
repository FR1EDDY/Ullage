import Foundation

/// One observation in a usage series: an instant and a 0...100 percentage.
///
/// The analytics deliberately work on this rather than on `UsageSample` so they
/// stay pure value-math with no knowledge of the database, and so a test can
/// state a scenario as a literal list of numbers.
struct SeriesPoint: Equatable, Sendable {
    let at: Date
    let percentUsed: Double

    init(at: Date, percentUsed: Double) {
        self.at = at
        self.percentUsed = percentUsed
    }
}

/// How fast a window is being consumed, in **percent-points per hour**.
///
/// Two rates, for two different jobs:
///   - the **window-long** rate (first→last sample of the current window) drives
///     the forecast, because it's what the whole session has averaged;
///   - the **short-horizon** rate (trailing 30 minutes) drives the anomaly
///     detector, because a runaway agent shows up in minutes and would be
///     diluted to nothing by a five-hour average.
enum BurnRate {
    /// The trailing span the anomaly detector looks at.
    static let shortHorizon: TimeInterval = 30 * 60

    /// Below this the elapsed time is too small to divide by — the rate would
    /// explode toward infinity on two samples written in the same instant.
    private static let minimumElapsed: TimeInterval = 1

    /// Splits a series wherever the percentage **drops**, which is what a window
    /// reset looks like from the outside: 84% one poll, 3% the next.
    ///
    /// This is the single most important guard in the file. Measured naively
    /// across a reset, the delta is negative and the "burn rate" comes out
    /// negative too — which would forecast a limit that heals itself. Splitting
    /// means every rate is measured inside one window and can only be ≥ 0.
    static func segments(_ points: [SeriesPoint]) -> [[SeriesPoint]] {
        guard !points.isEmpty else { return [] }
        let ordered = points.sorted { $0.at < $1.at }

        var result: [[SeriesPoint]] = []
        var current: [SeriesPoint] = [ordered[0]]
        for point in ordered.dropFirst() {
            if point.percentUsed < current[current.count - 1].percentUsed {
                result.append(current)
                current = [point]
            } else {
                current.append(point)
            }
        }
        result.append(current)
        return result
    }

    /// The segment the series is currently inside — everything since the last
    /// reset. This is what the live forecast measures.
    static func currentSegment(_ points: [SeriesPoint]) -> [SeriesPoint] {
        segments(points).last ?? []
    }

    /// Segments that have already ended, i.e. every one but the one in progress.
    /// A single-point segment is dropped: one observation describes no window.
    static func completedSegments(_ points: [SeriesPoint]) -> [[SeriesPoint]] {
        let all = segments(points)
        guard all.count > 1 else { return [] }
        return all.dropLast().filter { $0.count > 1 }
    }

    /// Percent-points per hour across the whole of the current window.
    ///
    /// `nil` — never a fabricated zero — when there isn't enough to divide:
    /// fewer than two samples, or two samples less than a second apart.
    static func windowLong(_ points: [SeriesPoint]) -> Double? {
        rate(over: currentSegment(points))
    }

    /// Percent-points per hour over the trailing `horizon`, measured inside the
    /// current window only.
    static func shortHorizon(
        _ points: [SeriesPoint],
        now: Date,
        horizon: TimeInterval = BurnRate.shortHorizon
    ) -> Double? {
        let recent = currentSegment(points).filter { $0.at >= now.addingTimeInterval(-horizon) }
        return rate(over: recent)
    }

    /// First→last rate across an already-segmented run of points.
    static func rate(over segment: [SeriesPoint]) -> Double? {
        guard segment.count >= 2,
              let first = segment.first,
              let last = segment.last
        else { return nil }

        let elapsed = last.at.timeIntervalSince(first.at)
        guard elapsed >= minimumElapsed else { return nil }

        let delta = last.percentUsed - first.percentUsed
        // A segment can't contain a reset by construction, so a negative delta
        // here would mean the input wasn't segmented. Clamped rather than
        // trusted: a negative burn rate is never a thing worth showing.
        guard delta >= 0 else { return nil }

        return delta / (elapsed / 3600)
    }

    /// One rate per completed window, for the anomaly detector's baseline.
    /// Windows the user never touched contribute a rate of 0 and would drag the
    /// median toward zero, making everything look like an anomaly — so only
    /// windows with actual movement count as "active".
    static func completedWindowRates(_ points: [SeriesPoint], activeOnly: Bool = true) -> [Double] {
        completedSegments(points).compactMap { segment in
            guard let rate = rate(over: segment) else { return nil }
            if activeOnly && rate <= 0 { return nil }
            return rate
        }
    }
}
