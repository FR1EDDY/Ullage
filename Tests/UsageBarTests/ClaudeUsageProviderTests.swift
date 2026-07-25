import XCTest
@testable import UsageBar

final class ClaudeUsageProviderTests: XCTestCase {
    /// The exact shape observed live on 2026-07-15: microsecond-precision
    /// `resets_at` and a `limits[]` array that says which window is binding.
    func testDecodesLiveShapeWithActiveLimits() throws {
        let json = """
        {
          "five_hour": { "utilization": 68.0, "resets_at": "2026-07-15T17:09:59.777408+00:00" },
          "seven_day": { "utilization": 28.0, "resets_at": "2026-07-17T04:59:59.777437+00:00" },
          "limits": [
            { "kind": "session", "is_active": true },
            { "kind": "weekly_all", "is_active": false }
          ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ClaudeUsageProvider.UsageResponse.self, from: json)
        let sessionActive = decoded.limits?.first(where: { $0.kind == "session" })?.isActive
        let weeklyActive = decoded.limits?.first(where: { $0.kind == "weekly_all" })?.isActive

        let session = ClaudeUsageProvider.window(from: decoded.fiveHour, isActiveOverride: sessionActive)
        let weekly = ClaudeUsageProvider.window(from: decoded.sevenDay, isActiveOverride: weeklyActive)

        XCTAssertEqual(session.percentUsed, 68.0)
        XCTAssertTrue(session.isActive)
        XCTAssertNotNil(session.resetsAt)

        XCTAssertEqual(weekly.percentUsed, 28.0)
        XCTAssertFalse(weekly.isActive)
    }

    func testMissingWindowProducesEmpty() {
        XCTAssertEqual(ClaudeUsageProvider.window(from: nil, isActiveOverride: nil), .empty)
    }

    /// The endpoint's utilization is always a 0...100 percent (confirmed
    /// live); guessing fraction-vs-percent by checking `value <= 1` misreads
    /// exactly 1% as 100% — this pins the clamp to stay a clamp.
    func testUtilizationClamping() {
        XCTAssertEqual(ClaudeUsageProvider.normalizedPercent(1.0), 1.0)
        XCTAssertEqual(ClaudeUsageProvider.normalizedPercent(150.0), 100.0)
        XCTAssertEqual(ClaudeUsageProvider.normalizedPercent(-5.0), 0.0)
        XCTAssertEqual(ClaudeUsageProvider.normalizedPercent(nil), 0.0)
    }

    func testPlanNameCapitalization() {
        XCTAssertEqual(ClaudeUsageProvider.planName(from: "pro"), "Pro")
        XCTAssertEqual(ClaudeUsageProvider.planName(from: "max"), "Max")
        XCTAssertNil(ClaudeUsageProvider.planName(from: nil))
        XCTAssertNil(ClaudeUsageProvider.planName(from: ""))
    }

    /// Schema drift (a field renamed or removed) shouldn't throw — every
    /// field here is optional by design so a partial response still decodes.
    func testMissingFieldsDecodeGracefully() throws {
        let decoded = try JSONDecoder().decode(ClaudeUsageProvider.UsageResponse.self, from: Data("{}".utf8))
        XCTAssertNil(decoded.fiveHour)
        XCTAssertNil(decoded.sevenDay)
        XCTAssertNil(decoded.limits)
    }
}
