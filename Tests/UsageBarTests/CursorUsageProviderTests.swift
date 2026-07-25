import XCTest
@testable import UsageBar

final class CursorUsageProviderTests: XCTestCase {
    /// The exact shape captured live on 2026-07-16 from `/api/usage-summary`.
    func testDecodesLiveShape() throws {
        let json = """
        {
          "billingCycleStart": "2026-07-04T21:29:55.000Z",
          "billingCycleEnd": "2026-08-04T21:29:55.000Z",
          "membershipType": "pro",
          "individualUsage": {
            "plan": {
              "enabled": true,
              "autoPercentUsed": 5.92,
              "apiPercentUsed": 22.711111111111112,
              "totalPercentUsed": 8.110144927536233
            }
          }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(CursorUsageProvider.UsageSummaryResponse.self, from: json)
        let plan = decoded.individualUsage?.plan

        XCTAssertEqual(plan?.totalPercentUsed ?? -1, 8.110144927536233, accuracy: 0.0001)
        XCTAssertEqual(plan?.autoPercentUsed ?? -1, 5.92, accuracy: 0.0001)
        XCTAssertEqual(plan?.apiPercentUsed ?? -1, 22.711111111111112, accuracy: 0.0001)
        XCTAssertNotNil(decoded.billingCycleEnd)
    }

    /// The spend fields, captured live on 2026-07-25 and cross-checked against
    /// Cursor's own dashboard tiles at the same moment.
    private static let spendJSON = """
    {
      "billingCycleStart": "2026-07-04T21:29:55.000Z",
      "billingCycleEnd": "2026-08-04T21:29:55.000Z",
      "isUnlimited": false,
      "limitType": "user",
      "membershipType": "pro",
      "individualUsage": {
        "onDemand": { "enabled": false, "limit": null, "remaining": null, "used": 0 },
        "plan": {
          "enabled": true,
          "apiPercentUsed": 58.48888888888889,
          "autoPercentUsed": 11.83666666666667,
          "totalPercentUsed": 17.92173913043478,
          "breakdown": { "bonus": 4183, "included": 2000, "total": 6183 },
          "limit": 2000,
          "remaining": 0,
          "used": 2000
        }
      }
    }
    """

    /// Cursor reports money in **cents**. This is the assertion that stops a
    /// stray factor of 100 from ever reaching the UI — `$61.83`, not `$6183`.
    func testSpendIsReportedInCentsAndConvertedToDollars() throws {
        let decoded = try JSONDecoder().decode(
            CursorUsageProvider.UsageSummaryResponse.self,
            from: Data(Self.spendJSON.utf8)
        )
        let plan = decoded.individualUsage?.plan

        XCTAssertEqual(CursorUsageProvider.dollars(fromCents: plan?.breakdown?.total) ?? -1, 61.83, accuracy: 0.001)
        XCTAssertEqual(CursorUsageProvider.dollars(fromCents: plan?.breakdown?.included) ?? -1, 20.00, accuracy: 0.001)
        XCTAssertEqual(CursorUsageProvider.dollars(fromCents: plan?.breakdown?.bonus) ?? -1, 41.83, accuracy: 0.001)
        XCTAssertEqual(CursorUsageProvider.dollars(fromCents: plan?.limit) ?? -1, 20.00, accuracy: 0.001)
        XCTAssertEqual(CursorUsageProvider.dollars(fromCents: plan?.remaining) ?? -1, 0.00, accuracy: 0.001)
        XCTAssertEqual(CursorUsageProvider.dollars(fromCents: decoded.individualUsage?.onDemand?.used) ?? -1, 0.00, accuracy: 0.001)
        XCTAssertNil(CursorUsageProvider.dollars(fromCents: nil))
    }

    /// The arithmetic that proved the unit in the first place, kept as a test:
    /// three independently-reported percentages resolve onto round dollar
    /// budgets and sum to `breakdown.total` with no remainder. If a future
    /// response stops satisfying this, the meaning of these fields has changed
    /// and the dollar figures must not be trusted until re-derived.
    func testSpendReconcilesWithTheReportedPercentages() throws {
        let decoded = try JSONDecoder().decode(
            CursorUsageProvider.UsageSummaryResponse.self,
            from: Data(Self.spendJSON.utf8)
        )
        let plan = try XCTUnwrap(decoded.individualUsage?.plan)
        let total = try XCTUnwrap(plan.breakdown?.total)

        // Implied total budget: spend ÷ fraction used.
        let impliedBudget = total / (try XCTUnwrap(plan.totalPercentUsed) / 100)
        XCTAssertEqual(impliedBudget, 34_500, accuracy: 1, "total budget should resolve to $345.00")

        // The two model budgets that make it up, and their spends.
        let autoSpend = 30_000 * (try XCTUnwrap(plan.autoPercentUsed) / 100)
        let apiSpend = 4_500 * (try XCTUnwrap(plan.apiPercentUsed) / 100)
        XCTAssertEqual(autoSpend, 3_551, accuracy: 0.5)
        XCTAssertEqual(apiSpend, 2_632, accuracy: 0.5)
        XCTAssertEqual(autoSpend + apiSpend, total, accuracy: 1, "auto + api must account for the whole total")
    }

    /// A response without the spend block must still yield a usable reading —
    /// the percentage meters are the part that has to keep working.
    func testMissingSpendBlockStillDecodes() throws {
        let json = """
        { "billingCycleEnd": "2026-08-04T21:29:55.000Z",
          "individualUsage": { "plan": { "totalPercentUsed": 8.1 } } }
        """
        let decoded = try JSONDecoder().decode(
            CursorUsageProvider.UsageSummaryResponse.self,
            from: Data(json.utf8)
        )
        XCTAssertNil(decoded.individualUsage?.plan?.breakdown?.total)
        XCTAssertNil(decoded.individualUsage?.onDemand?.used)
        XCTAssertEqual(decoded.individualUsage?.plan?.totalPercentUsed ?? -1, 8.1, accuracy: 0.0001)
    }

    /// `hasSpend` gates the whole Cursor cost card, so it must be false for a
    /// reading that carries only percentages.
    func testHasSpendGatesTheCard() {
        let withoutSpend = CursorUsage(
            percentUsed: 18, firstPartyPercentUsed: 12, apiPercentUsed: 58,
            resetsAt: nil, cycleLabel: nil, observedAt: Date()
        )
        XCTAssertFalse(withoutSpend.hasSpend)

        let withSpend = CursorUsage(
            percentUsed: 18, firstPartyPercentUsed: 12, apiPercentUsed: 58,
            resetsAt: nil, cycleLabel: nil, totalSpend: 61.83, observedAt: Date()
        )
        XCTAssertTrue(withSpend.hasSpend)
    }

    /// Spend rides in the persisted reading (so a cold start shows it) but the
    /// raw body must still stay out of the cache.
    func testSpendSurvivesTheCachedReadingButRawPayloadDoesNot() throws {
        let usage = CursorUsage(
            percentUsed: 17.92, firstPartyPercentUsed: 11.84, apiPercentUsed: 58.49,
            resetsAt: Date(timeIntervalSince1970: 1_785_000_000),
            startsAt: Date(timeIntervalSince1970: 1_782_000_000),
            cycleLabel: nil,
            totalSpend: 61.83, onDemandSpend: 0, includedAllowance: 20, includedRemaining: 0,
            observedAt: Date(timeIntervalSince1970: 1_784_000_000),
            rawPayload: Data(String(repeating: "x", count: 4096).utf8)
        )
        let decoded = try JSONDecoder().decode(CursorUsage.self, from: JSONEncoder().encode(usage))

        XCTAssertEqual(decoded.totalSpend, 61.83)
        XCTAssertEqual(decoded.onDemandSpend, 0)
        XCTAssertEqual(decoded.includedAllowance, 20)
        XCTAssertEqual(decoded.includedRemaining, 0)
        XCTAssertEqual(decoded.startsAt, usage.startsAt)
        XCTAssertNil(decoded.rawPayload)
    }

    func testNormalizedPercentClamps() {
        XCTAssertEqual(CursorUsageProvider.normalizedPercent(150), 100)
        XCTAssertEqual(CursorUsageProvider.normalizedPercent(-5), 0)
        XCTAssertEqual(CursorUsageProvider.normalizedPercent(nil), 0)
        XCTAssertEqual(CursorUsageProvider.normalizedPercent(42), 42)
    }

    /// Schema drift shouldn't throw — every field here is optional by design.
    func testMissingFieldsDecodeGracefully() throws {
        let decoded = try JSONDecoder().decode(CursorUsageProvider.UsageSummaryResponse.self, from: Data("{}".utf8))
        XCTAssertNil(decoded.individualUsage)
        XCTAssertNil(decoded.billingCycleEnd)
    }
}
