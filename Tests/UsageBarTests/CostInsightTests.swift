import XCTest
import SwiftUI
@testable import UsageBar

/// The Tier-1/Tier-2 insights: arithmetic over data we already hold, with no
/// inference about whether a different choice would have worked.
final class CostInsightTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_784_000_000)

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Opus-shaped rates: input 5, output 25, 5m write 6.25, 1h write 10,
    /// read 0.5 — i.e. the published 1.25× / 2× / 0.1× multipliers.
    private let opus = ModelRate(
        inputPerMTok: 5, outputPerMTok: 25,
        cacheWrite5mPerMTok: 6.25, cacheWrite1hPerMTok: 10, cacheReadPerMTok: 0.5
    )

    private func pricing() throws -> ModelPricing {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("insight-prices-\(UUID().uuidString).json")
        let json = """
        { "schemaVersion": 1, "models": {
            "claude-opus-4-8":  { "inputPerMTok": 5, "outputPerMTok": 25, "cacheWrite5mPerMTok": 6.25, "cacheWrite1hPerMTok": 10, "cacheReadPerMTok": 0.5 },
            "claude-opus-5":    { "inputPerMTok": 5, "outputPerMTok": 25, "cacheWrite5mPerMTok": 6.25, "cacheWrite1hPerMTok": 10, "cacheReadPerMTok": 0.5 },
            "claude-sonnet-5":  { "inputPerMTok": 3, "outputPerMTok": 15, "cacheWrite5mPerMTok": 3.75, "cacheWrite1hPerMTok": 6, "cacheReadPerMTok": 0.3 },
            "claude-haiku-4-5": { "inputPerMTok": 1, "outputPerMTok": 5, "cacheWrite5mPerMTok": 1.25, "cacheWrite1hPerMTok": 2, "cacheReadPerMTok": 0.1 }
        } }
        """
        try json.write(to: url, atomically: true, encoding: .utf8)
        return try ModelPricing(contentsOf: url)
    }

    private func record(
        _ id: String,
        model: String = "claude-opus-4-8",
        project: String? = "/Users/me/Projects/alpha",
        hoursAgo: Double = 1,
        tokens: TokenCounts
    ) -> CostRecord {
        CostRecord(
            identity: id,
            timestamp: now.addingTimeInterval(-hoursAgo * 3600),
            model: model,
            tokens: tokens,
            project: project
        )
    }

    // MARK: - Cache economics

    /// Derived from the rate table, not from hardcoded multipliers — so this
    /// pins the arithmetic itself: a read saves the gap between the input and
    /// read rates, a write costs the gap in the other direction.
    func testCacheEconomicsComputesSavingsAndPremiumExactly() {
        let tokens = TokenCounts(
            input: 0, output: 0,
            cacheWrite5m: 1_000_000,
            cacheWrite1h: 1_000_000,
            cacheRead: 4_000_000
        )
        let economics = opus.cacheEconomics(for: tokens)

        // Reads: 4M × (5 − 0.5) / 1M = $18.00
        XCTAssertEqual(economics.savedByReads, 18.0, accuracy: 0.0001)
        // Writes: 1M × (6.25 − 5) + 1M × (10 − 5) = $1.25 + $5.00 = $6.25
        XCTAssertEqual(economics.premiumOnWrites, 6.25, accuracy: 0.0001)
        XCTAssertEqual(economics.net, 11.75, accuracy: 0.0001)
        XCTAssertEqual(economics.readsPerWrittenToken ?? 0, 2.0, accuracy: 0.0001)
    }

    /// Caching genuinely can lose money — writing a large prompt into the
    /// one-hour cache and then reading it back once costs more than not caching
    /// at all. Reporting that is the point.
    func testCachingCanCostMoreThanItSaves() {
        let tokens = TokenCounts(cacheWrite1h: 1_000_000, cacheRead: 500_000)
        let economics = opus.cacheEconomics(for: tokens)

        // Saved 0.5M × 4.5 = $2.25; paid 1M × 5 = $5.00.
        XCTAssertEqual(economics.net, -2.75, accuracy: 0.0001)
        XCTAssertLessThan(economics.net, 0)
    }

    /// The break-even ratios the tooltip quotes: a 1-hour write needs ~1.11
    /// reads per written token to pay for itself, a 5-minute write ~0.28.
    func testBreakEvenRatiosMatchTheRateTable() {
        let oneHourBreakEven = (opus.cacheWrite1hPerMTok - opus.inputPerMTok)
            / (opus.inputPerMTok - opus.cacheReadPerMTok)
        let fiveMinuteBreakEven = (opus.cacheWrite5mPerMTok - opus.inputPerMTok)
            / (opus.inputPerMTok - opus.cacheReadPerMTok)
        XCTAssertEqual(oneHourBreakEven, 1.111, accuracy: 0.001)
        XCTAssertEqual(fiveMinuteBreakEven, 0.278, accuracy: 0.001)

        // Exactly at break-even the net is zero, which is the definition.
        let atBreakEven = TokenCounts(cacheWrite1h: 900_000, cacheRead: 1_000_000)
        XCTAssertEqual(opus.cacheEconomics(for: atBreakEven).net, 0, accuracy: 0.001)
    }

    func testCacheEconomicsAccumulateAcrossASummary() throws {
        let records = (0..<3).map {
            record("r\($0)", tokens: TokenCounts(cacheWrite5m: 1_000_000, cacheRead: 2_000_000))
        }
        let summary = ClaudeCostProvider.summarize(
            records: records, now: now, pricing: try pricing(), calendar: utcCalendar
        )
        // Per record: saved 2M × 4.5 = $9.00, paid 1M × 1.25 = $1.25 → net 7.75.
        XCTAssertEqual(summary.cache.net, 23.25, accuracy: 0.001)
        XCTAssertEqual(summary.cache.readTokens, 6_000_000)
        XCTAssertEqual(summary.cache.writeTokens5m, 3_000_000)
        XCTAssertEqual(summary.cache.writeTokens1h, 0)
    }

    /// Unpriced models are excluded from the totals, so they must be excluded
    /// from the cache figures too — a partly-counted saving is a wrong saving.
    func testUnpricedModelsDoNotContributeToCacheEconomics() throws {
        let records = [
            record("a", tokens: TokenCounts(cacheWrite5m: 1_000_000, cacheRead: 2_000_000)),
            record("b", model: "claude-unknown-9", tokens: TokenCounts(cacheRead: 50_000_000))
        ]
        let summary = ClaudeCostProvider.summarize(
            records: records, now: now, pricing: try pricing(), calendar: utcCalendar
        )
        XCTAssertEqual(summary.cache.readTokens, 2_000_000)
        XCTAssertEqual(summary.unpricedRequests, 1)
    }

    // MARK: - Per-project

    func testProjectsAreAggregatedAndSortedBySpend() throws {
        let records = [
            record("a", project: "/Users/me/alpha", tokens: TokenCounts(output: 1_000_000)),
            record("b", project: "/Users/me/beta", tokens: TokenCounts(output: 3_000_000)),
            record("c", project: "/Users/me/beta", tokens: TokenCounts(output: 1_000_000)),
            record("d", project: nil, tokens: TokenCounts(output: 1_000_000))
        ]
        let summary = ClaudeCostProvider.summarize(
            records: records, now: now, pricing: try pricing(), calendar: utcCalendar
        )

        XCTAssertEqual(summary.byProject.map(\.name), ["/Users/me/beta", "/Users/me/alpha"])
        XCTAssertEqual(summary.byProject[0].cost, 100, accuracy: 0.001)   // 4M output × $25/M
        XCTAssertEqual(summary.byProject[0].requestCount, 2)
        XCTAssertEqual(summary.byProject[1].cost, 25, accuracy: 0.001)
        // A record with no cwd still counts toward the total; it just can't be
        // attributed, and inventing a bucket for it would be a lie.
        XCTAssertEqual(summary.last30Days, 150, accuracy: 0.001)
    }

    func testProjectDisplayNameIsTheFolder() {
        XCTAssertEqual(ProjectCostSectionView.displayName("/Users/me/Desktop/UsageTracker"), "UsageTracker")
        XCTAssertEqual(ProjectCostSectionView.displayName("/Users/me/my-app-with-hyphens"), "my-app-with-hyphens")
        XCTAssertEqual(ProjectCostSectionView.displayName("bare"), "bare")
    }

    // MARK: - Model re-pricing (Tier 2)

    /// A pure re-pricing of the same tokens. Not a recommendation, and the test
    /// name says so: it asserts arithmetic, nothing about which model to use.
    func testAlternativesRepriceTheSameTokens() throws {
        let tokens = TokenCounts(input: 1_000_000, output: 1_000_000)
        let alternatives = ClaudeCostProvider.alternatives(for: tokens, pricing: try pricing(), at: now)

        XCTAssertEqual(alternatives.map(\.model), ClaudeCostProvider.referenceModels)
        // Opus 5: 5 + 25 = $30 · Sonnet 5: 3 + 15 = $18 · Haiku 4.5: 1 + 5 = $6
        XCTAssertEqual(alternatives[0].cost, 30, accuracy: 0.001)
        XCTAssertEqual(alternatives[1].cost, 18, accuracy: 0.001)
        XCTAssertEqual(alternatives[2].cost, 6, accuracy: 0.001)
    }

    func testAlternativesAreEmptyWithoutTokens() throws {
        XCTAssertTrue(
            ClaudeCostProvider.alternatives(for: TokenCounts(), pricing: try pricing(), at: now).isEmpty
        )
    }

    /// The re-pricing includes cache tokens at each model's own cache rates, so
    /// a cache-heavy workload doesn't get compared on input/output alone.
    func testAlternativesPriceCacheTokensToo() throws {
        let tokens = TokenCounts(cacheWrite1h: 1_000_000, cacheRead: 1_000_000)
        let alternatives = ClaudeCostProvider.alternatives(for: tokens, pricing: try pricing(), at: now)
        // Opus 5: 10 + 0.5 = $10.50 · Haiku 4.5: 2 + 0.1 = $2.10
        XCTAssertEqual(alternatives[0].cost, 10.5, accuracy: 0.001)
        XCTAssertEqual(alternatives[2].cost, 2.1, accuracy: 0.001)
    }

    // MARK: - Cursor constraint facts

    private func cursor(
        auto: Double, api: Double,
        includedRemaining: Double? = nil,
        onDemandEnabled: Bool? = nil
    ) -> CursorUsage {
        CursorUsage(
            percentUsed: (auto + api) / 2,
            firstPartyPercentUsed: auto,
            apiPercentUsed: api,
            resetsAt: now.addingTimeInterval(86_400),
            cycleLabel: nil,
            totalSpend: 61.83,
            includedAllowance: 20,
            includedRemaining: includedRemaining,
            onDemandEnabled: onDemandEnabled,
            observedAt: now
        )
    }

    /// Cursor meters first-party and API models against separate budgets, so
    /// the blended figure can look calm while one half is nearly gone.
    func testBindingLimitIsNamedOnlyWhenThePoolsDiverge() {
        let diverged = CursorCostSectionView(
            usage: cursor(auto: 11.83666666666667, api: 58.48888888888889), brandColor: .blue, brandGradient: LinearGradient(colors: [.blue], startPoint: .leading, endPoint: .trailing)
        )
        XCTAssertEqual(
            diverged.constraintLineForTesting,
            "Binding limit: API models at 58% (first-party 12%)"
        )

        // Close together: the blended meter already says everything.
        let even = CursorCostSectionView(
            usage: cursor(auto: 30, api: 34), brandColor: .blue, brandGradient: LinearGradient(colors: [.blue], startPoint: .leading, endPoint: .trailing)
        )
        XCTAssertNil(even.constraintLineForTesting)
    }

    /// Allowance spent *and* on-demand off is the one combination that stops
    /// work outright. Either alone is unremarkable.
    func testBlockedWarningNeedsBothConditions() {
        let gradient = LinearGradient(colors: [.blue], startPoint: .leading, endPoint: .trailing)

        let blocked = CursorCostSectionView(
            usage: cursor(auto: 12, api: 58, includedRemaining: 0, onDemandEnabled: false),
            brandColor: .blue, brandGradient: gradient
        )
        XCTAssertNotNil(blocked.blockedWarningForTesting)

        let hasOverflow = CursorCostSectionView(
            usage: cursor(auto: 12, api: 58, includedRemaining: 0, onDemandEnabled: true),
            brandColor: .blue, brandGradient: gradient
        )
        XCTAssertNil(hasOverflow.blockedWarningForTesting)

        let hasAllowanceLeft = CursorCostSectionView(
            usage: cursor(auto: 12, api: 58, includedRemaining: 8, onDemandEnabled: false),
            brandColor: .blue, brandGradient: gradient
        )
        XCTAssertNil(hasAllowanceLeft.blockedWarningForTesting)

        // Unknown on-demand state says nothing rather than guessing.
        let unknown = CursorCostSectionView(
            usage: cursor(auto: 12, api: 58, includedRemaining: 0, onDemandEnabled: nil),
            brandColor: .blue, brandGradient: gradient
        )
        XCTAssertNil(unknown.blockedWarningForTesting)
    }
}
