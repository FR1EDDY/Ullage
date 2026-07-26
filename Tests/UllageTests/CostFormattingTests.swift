import XCTest
@testable import Ullage

/// The display layer of the Cost card. Pure formatting, so it's cheap to pin —
/// and these are the strings the user actually reads.
final class CostFormattingTests: XCTestCase {
    func testModelDisplayNames() {
        XCTAssertEqual(CostSectionView.displayName("claude-opus-4-8"), "Opus 4.8")
        XCTAssertEqual(CostSectionView.displayName("claude-sonnet-5"), "Sonnet 5")
        XCTAssertEqual(CostSectionView.displayName("claude-haiku-4-5-20251001"), "Haiku 4.5")
        XCTAssertEqual(CostSectionView.displayName("claude-fable-5"), "Fable 5")
        // Anything we don't recognise still renders as itself rather than empty.
        XCTAssertEqual(CostSectionView.displayName("mystery"), "Mystery")
    }

    func testTokenAbbreviation() {
        XCTAssertEqual(CostSectionView.tokens(0), "0")
        XCTAssertEqual(CostSectionView.tokens(999), "999")
        XCTAssertEqual(CostSectionView.tokens(1_500), "1.5K")
        XCTAssertEqual(CostSectionView.tokens(2_400_000), "2.4M")
        XCTAssertEqual(CostSectionView.tokens(276_800_205), "276.8M")
        XCTAssertEqual(CostSectionView.tokens(1_250_000_000), "1.25B")
    }

    /// A real but tiny spend must not render as "$0.00", which reads as a
    /// broken meter rather than as a small number.
    func testCurrencyKeepsSubCentAmountsVisible() {
        XCTAssertTrue(CostSectionView.currency(0).hasSuffix("0.00"))
        XCTAssertTrue(CostSectionView.currency(27.4321).hasSuffix("27.43"))
        let tiny = CostSectionView.currency(0.0004)
        XCTAssertFalse(tiny.hasSuffix("0.00"), "sub-cent spend collapsed to zero: \(tiny)")
    }

    /// Must read "$45.67", not the "US$ 45.67" a non-US system locale produces.
    /// Anthropic's and Cursor's own dashboards both say "$", and these figures
    /// exist to be checked against them — so this is pinned rather than left to
    /// whatever locale the machine happens to have.
    func testCurrencyUsesADollarSignRegardlessOfSystemLocale() {
        let formatted = CostSectionView.currency(45.67)
        XCTAssertTrue(formatted.contains("$"), formatted)
        XCTAssertFalse(formatted.contains("US$"), "locale leaked into the symbol: \(formatted)")
        XCTAssertTrue(formatted.hasSuffix("45.67"), formatted)
    }

    /// The chart shows a fixed 30-day timeline, including days with no usage —
    /// a gap is information, and compressing it out would make an idle stretch
    /// read as continuous work.
    func testChartFillsMissingDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let today = calendar.startOfDay(for: now)
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: today)!

        var summary = CostSummary()
        summary.daily = [
            DailyCost(day: threeDaysAgo, cost: 4, tokens: 100),
            DailyCost(day: today, cost: 9, tokens: 200)
        ]

        let filled = CostSectionView.filledDays(from: summary, count: 30, calendar: calendar, now: now)
        XCTAssertEqual(filled.count, 30)
        XCTAssertEqual(filled.map(\.day), filled.map(\.day).sorted(), "chart must run oldest to newest")
        XCTAssertEqual(filled.last?.cost, 9)
        XCTAssertEqual(filled[filled.count - 4].cost, 4)
        XCTAssertEqual(filled[filled.count - 2].cost, 0, "a day with no usage stays in the timeline")
        XCTAssertEqual(filled.filter { $0.cost > 0 }.count, 2)
    }
}
