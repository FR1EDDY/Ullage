import Foundation

/// Order statistics for the forecasting layer.
///
/// The baseline here is a **percentile, not a mean**, and that choice is the
/// whole reason this file exists. Consumption is bursty and session-quantized:
/// you either hammer a 5-hour window or you don't touch it at all. A mean of
/// "mostly zero, occasionally huge" under-predicts the spikes that actually
/// exhaust a limit and over-predicts the idle days — it describes a usage
/// pattern nobody has.
enum Percentile {
    /// The `q`-quantile (0...1) using **linear interpolation between order
    /// statistics** — the R-7 definition, which is what NumPy and pandas use by
    /// default.
    ///
    /// Nearest-rank would be wrong here for a reason that bites at exactly the
    /// sample sizes we have: with 6 observations, nearest-rank P90 simply
    /// returns the largest one, so "the 90th percentile" and "the worst case
    /// ever seen" become the same number and the forecast inherits every
    /// outlier whole.
    ///
    /// Returns `nil` for an empty input rather than a sentinel — there is no
    /// honest percentile of nothing.
    static func p(_ q: Double, of values: [Double]) -> Double? {
        // `Int(Double.nan)` is a hard trap in Swift, and NaN survives `min`/`max`
        // (every comparison against it is false, so a clamp doesn't clamp it).
        // No current caller can pass one, but this is a crash rather than a
        // wrong answer, so it's guarded rather than reasoned about.
        guard q.isFinite else { return nil }

        // Filtered *before* the size shortcuts, not after. With the early
        // returns above this, a single-element `[.infinity]` was handed back
        // untouched — the guard existed but nothing reached it.
        let finite = values.filter(\.isFinite)
        guard !finite.isEmpty else { return nil }
        guard finite.count > 1 else { return finite[0] }

        let clampedQ = min(max(q, 0), 1)
        let sorted = finite.sorted()
        // Rank as a fractional index into the sorted values.
        let rank = Double(sorted.count - 1) * clampedQ
        let lowerIndex = Int(rank.rounded(.down))
        let upperIndex = Int(rank.rounded(.up))
        guard lowerIndex != upperIndex else { return sorted[lowerIndex] }

        let weight = rank - Double(lowerIndex)
        return sorted[lowerIndex] + weight * (sorted[upperIndex] - sorted[lowerIndex])
    }

    /// The median, used as the anomaly detector's baseline.
    ///
    /// Deliberately a median rather than a mean: the thing we're detecting is a
    /// runaway session, and a mean would let that very session inflate the
    /// baseline it is being measured against — the detector would quietly raise
    /// its own threshold to accommodate the anomaly.
    static func median(of values: [Double]) -> Double? {
        p(0.5, of: values)
    }
}
