import Foundation

/// Everything the UI needs to say about where usage is heading.
struct Forecasts: Equatable, Sendable {
    var claudeSession: SessionForecast?
    var claudeWeekly: WindowProjection?
    var cursorCycle: WindowProjection?
    /// A runaway session is in progress. Deliberately a single flag rather than
    /// per-window: the user needs to know *something* is wrong, not which meter
    /// noticed first.
    var anomalyFiring: Bool = false

    static let none = Forecasts()

    var isEmpty: Bool {
        claudeSession == nil && claudeWeekly == nil && cursorCycle == nil
    }
}

/// The only part of the forecasting layer that touches I/O: it pulls series out
/// of `SnapshotStore` and hands them to the pure analytics.
///
/// Keeping the split this sharp is what makes the moat testable — every rule
/// that could be *wrong* lives in a pure function, and this file only decides
/// which numbers to feed it.
actor ForecastEngine {
    private let store: SnapshotStore?
    /// Carried across polls because the anomaly detector needs to know how many
    /// consecutive breaches it has seen; a stateless detector could only ever
    /// fire instantly and flap.
    private var anomalyState: AnomalyState = .idle

    init(store: SnapshotStore? = SnapshotStore.shared) {
        self.store = store
    }

    /// How much history to load. Wide enough for the 8-day session lookback and
    /// the 7-day anomaly baseline, narrow enough that this stays a small read.
    private static let historyWindow: TimeInterval = 10 * 24 * 60 * 60

    /// `async` because `SnapshotStore` is a separate actor — the history read
    /// hops to it and back. The analytics themselves are synchronous and pure.
    func forecasts(
        claudeSessionResetsAt: Date?,
        claudeWeeklyResetsAt: Date?,
        cursorResetsAt: Date?,
        now: Date = Date()
    ) async -> Forecasts {
        guard let store else { return .none }
        let since = now.addingTimeInterval(-Self.historyWindow)

        let sessionPoints = (try? await store.samples(provider: .claude, kind: .session, since: since))
            .map(Self.series) ?? []
        let weeklyPoints = (try? await store.samples(provider: .claude, kind: .weekly, since: since))
            .map(Self.series) ?? []
        let cursorPoints = (try? await store.samples(provider: .cursor, kind: .total, since: since))
            .map(Self.series) ?? []

        anomalyState = AnomalyDetector.advance(
            state: anomalyState,
            shortHorizonRate: BurnRate.shortHorizon(sessionPoints, now: now),
            baseline: AnomalyDetector.baseline(points: sessionPoints, now: now)
        )

        return Forecasts(
            claudeSession: Forecast.session(
                points: sessionPoints,
                resetsAt: claudeSessionResetsAt,
                now: now
            ),
            claudeWeekly: WeeklyProjection.weekly(
                sessionPoints: sessionPoints,
                weeklyPoints: weeklyPoints,
                resetsAt: claudeWeeklyResetsAt,
                now: now
            ),
            cursorCycle: WeeklyProjection.cycle(
                points: cursorPoints,
                resetsAt: cursorResetsAt,
                now: now
            ),
            anomalyFiring: anomalyState.isFiring
        )
    }

    static func series(_ samples: [UsageSample]) -> [SeriesPoint] {
        samples.map { SeriesPoint(at: $0.capturedAt, percentUsed: $0.percentUsed) }
    }
}
