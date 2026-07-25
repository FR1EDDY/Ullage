import XCTest
@testable import UsageBar

final class ModelPricingTests: XCTestCase {
    /// The table as it ships in the repo — loaded by path rather than through
    /// `ModelPricing()` so a user override on the machine running these tests
    /// can't change the result.
    private func bundledPricing() throws -> ModelPricing {
        try ModelPricing(contentsOf: Self.bundledTableURL)
    }

    private static let bundledTableURL: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // UsageBarTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("Sources/UsageBar/Resources/model_prices.json")

    private let referenceDate = Date(timeIntervalSince1970: 1_764_000_000) // 2025-11-24

    func testBundledTableLoadsAndPricesCurrentModels() throws {
        let pricing = try bundledPricing()
        for model in ["claude-opus-5", "claude-opus-4-8", "claude-sonnet-5", "claude-fable-5", "claude-haiku-4-5"] {
            XCTAssertNotNil(pricing.rate(for: model, at: referenceDate), "no price for \(model)")
        }
    }

    /// Anthropic derives cache pricing from the input rate: read 0.1×, 5-minute
    /// write 1.25×, 1-hour write 2×. Deriving them by hand in a JSON file is
    /// exactly the sort of thing a typo hides in, so pin the relationship.
    func testCacheRatesFollowThePublishedMultipliers() throws {
        let pricing = try bundledPricing()
        let models = [
            "claude-fable-5", "claude-mythos-5", "claude-opus-5", "claude-opus-4-8",
            "claude-opus-4-7", "claude-opus-4-6", "claude-sonnet-5", "claude-sonnet-4-6",
            "claude-haiku-4-5"
        ]
        for model in models {
            let rate = try XCTUnwrap(pricing.rate(for: model, at: referenceDate), model)
            XCTAssertEqual(rate.cacheReadPerMTok, rate.inputPerMTok * 0.1, accuracy: 0.0001, "\(model) cache read")
            XCTAssertEqual(rate.cacheWrite5mPerMTok, rate.inputPerMTok * 1.25, accuracy: 0.0001, "\(model) 5m write")
            XCTAssertEqual(rate.cacheWrite1hPerMTok, rate.inputPerMTok * 2.0, accuracy: 0.0001, "\(model) 1h write")
        }
    }

    /// The compiled-in fallback exists so a missing resource bundle degrades
    /// instead of crashing — but two copies of the same prices can drift. This
    /// makes drift a test failure rather than a silent mispricing.
    func testCompiledFallbackAgreesWithBundledTable() throws {
        let pricing = try bundledPricing()
        // Checked on both sides of Sonnet 5's promotional window — a fallback
        // that agreed only on standard pricing would silently overcharge
        // during it, which is the failure this test exists to prevent.
        let dates = [isoDate("2026-07-25T12:00:00Z"), isoDate("2026-09-01T12:00:00Z")]
        for model in ModelPricing.fallbackModelIDs {
            for date in dates {
                let fallback = try XCTUnwrap(ModelPricing.compiledFallback.rate(for: model, at: date), model)
                let bundled = try XCTUnwrap(pricing.rate(for: model, at: date), model)
                XCTAssertEqual(fallback, bundled, "compiled fallback disagrees with model_prices.json for \(model) at \(date)")
            }
        }
    }

    /// Logs carry both bare aliases and dated snapshot ids for what is one
    /// priced model, so `claude-haiku-4-5-20251001` must resolve.
    func testDatedSnapshotIDsResolveToTheirAlias() throws {
        let pricing = try bundledPricing()
        let dated = try XCTUnwrap(pricing.rate(for: "claude-haiku-4-5-20251001", at: referenceDate))
        let alias = try XCTUnwrap(pricing.rate(for: "claude-haiku-4-5", at: referenceDate))
        XCTAssertEqual(dated, alias)

        XCTAssertEqual(ModelPricing.strippingDateSuffix("claude-haiku-4-5-20251001"), "claude-haiku-4-5")
        // Not a date — a version segment must not be mistaken for one.
        XCTAssertNil(ModelPricing.strippingDateSuffix("claude-opus-4-8"))
        XCTAssertNil(ModelPricing.strippingDateSuffix("claude-sonnet-5"))
    }

    /// Sonnet 5 is discounted through 2026-08-31. Charging the standard rate
    /// during that window overstates its cost by 50%.
    func testPromotionalPricingAppliesOnlyInsideItsWindow() throws {
        let pricing = try bundledPricing()
        let during = try XCTUnwrap(pricing.rate(for: "claude-sonnet-5", at: isoDate("2026-07-25T12:00:00Z")))
        XCTAssertEqual(during.inputPerMTok, 2.0)
        XCTAssertEqual(during.outputPerMTok, 10.0)

        // The window runs to the end of its final day, not its first instant.
        let lastDay = try XCTUnwrap(pricing.rate(for: "claude-sonnet-5", at: isoDate("2026-08-31T23:00:00Z")))
        XCTAssertEqual(lastDay.inputPerMTok, 2.0)

        let after = try XCTUnwrap(pricing.rate(for: "claude-sonnet-5", at: isoDate("2026-09-01T12:00:00Z")))
        XCTAssertEqual(after.inputPerMTok, 3.0)
        XCTAssertEqual(after.outputPerMTok, 15.0)
    }

    /// The acceptance criterion: a model we have no price for reports as
    /// unknown so the UI can say "unpriced", never as a free $0.
    func testUnknownModelHasNoRate() throws {
        let pricing = try bundledPricing()
        XCTAssertNil(pricing.rate(for: "claude-imaginary-9", at: referenceDate))
        XCTAssertNil(pricing.rate(for: "<synthetic>", at: referenceDate))
        XCTAssertFalse(pricing.knowsModel("gpt-nonsense"))
    }

    func testCostMathAcrossAllFiveTokenClasses() {
        let rate = ModelRate(
            inputPerMTok: 5,
            outputPerMTok: 25,
            cacheWrite5mPerMTok: 6.25,
            cacheWrite1hPerMTok: 10,
            cacheReadPerMTok: 0.5
        )
        let tokens = TokenCounts(
            input: 1_000_000,
            output: 1_000_000,
            cacheWrite5m: 1_000_000,
            cacheWrite1h: 1_000_000,
            cacheRead: 1_000_000
        )
        // 5 + 25 + 6.25 + 10 + 0.5
        XCTAssertEqual(rate.cost(for: tokens), 46.75, accuracy: 0.0001)
        XCTAssertEqual(rate.cost(for: TokenCounts()), 0)
    }

    private func isoDate(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: value)!
    }
}
