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
