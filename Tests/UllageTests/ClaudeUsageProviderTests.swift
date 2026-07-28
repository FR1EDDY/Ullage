import XCTest
@testable import Ullage

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

    /// The in-app sign-in path can only learn the tier from the organizations
    /// response, which is undocumented and has carried it under more than one
    /// key. Whichever shape arrives must render the same badge text as the
    /// Claude Code credentials path produces.
    func testPlanNameFromOrganizationAcceptsKnownShapes() {
        XCTAssertEqual(
            ClaudeUsageProvider.planName(fromOrganization: ["subscription_type": "pro"]), "Pro"
        )
        XCTAssertEqual(
            ClaudeUsageProvider.planName(fromOrganization: ["rate_limit_tier": "claude_max"]), "Max"
        )
        // Tier strings arrive suffixed in some responses.
        XCTAssertEqual(
            ClaudeUsageProvider.planName(fromOrganization: ["billing_type": "pro_2025"]), "Pro"
        )
        XCTAssertEqual(
            ClaudeUsageProvider.planName(fromOrganization: ["capabilities": ["chat", "claude_max"]]), "Max"
        )
    }

    /// A missing badge is the accepted outcome; a wrong one is not. Anything
    /// this function can't confidently read as a tier has to come back nil.
    func testPlanNameFromOrganizationRejectsNonTiers() {
        XCTAssertNil(ClaudeUsageProvider.planName(fromOrganization: [:]))
        XCTAssertNil(ClaudeUsageProvider.planName(fromOrganization: ["uuid": "abc"]))
        // "default" means an unsubscribed account, not a plan called Default.
        XCTAssertNil(ClaudeUsageProvider.planName(fromOrganization: ["subscription_type": "default"]))
        // Feature flags share the `claude_` prefix with tier capabilities.
        XCTAssertNil(
            ClaudeUsageProvider.planName(fromOrganization: ["capabilities": ["claude_1p", "chat"]])
        )
    }

    /// Schema drift (a field renamed or removed) shouldn't throw — every
    /// field here is optional by design so a partial response still decodes.
    func testMissingFieldsDecodeGracefully() throws {
        let decoded = try JSONDecoder().decode(ClaudeUsageProvider.UsageResponse.self, from: Data("{}".utf8))
        XCTAssertNil(decoded.fiveHour)
        XCTAssertNil(decoded.sevenDay)
        XCTAssertNil(decoded.limits)
    }

    /// The raw body rides along on the reading (so history can keep a copy) but
    /// must stay out of the UserDefaults cache, which exists to make cold start
    /// fast and would be defeated by a few KB of JSON per poll.
    func testRawPayloadIsNotPersistedInTheCachedReading() throws {
        let usage = ClaudeUsage(
            planName: "Max",
            session: UsageWindow(percentUsed: 68, resetsAt: nil, isActive: true),
            weeklyAllModels: UsageWindow(percentUsed: 28, resetsAt: nil, isActive: false),
            observedAt: Date(timeIntervalSince1970: 1_760_000_000),
            rawPayload: Data(String(repeating: "x", count: 4096).utf8)
        )

        let encoded = try JSONEncoder().encode(usage)
        let decoded = try JSONDecoder().decode(ClaudeUsage.self, from: encoded)

        XCTAssertNil(decoded.rawPayload)
        XCTAssertLessThan(encoded.count, 256)
        XCTAssertEqual(decoded.planName, "Max")
        XCTAssertEqual(decoded.session.percentUsed, 68)
        XCTAssertEqual(decoded.weeklyAllModels.percentUsed, 28)
        XCTAssertEqual(decoded.observedAt, usage.observedAt)
    }

    // MARK: - Rate-limit header strategy

    /// The shape the third strategy reads: utilization and reset for both
    /// unified windows, straight off the response headers.
    func testRateLimitHeadersProduceBothWindows() throws {
        let resetsAt = Date(timeIntervalSince1970: 1_760_018_000)
        let weeklyResetsAt = Date(timeIntervalSince1970: 1_760_400_000)
        let usage = try XCTUnwrap(ClaudeUsageProvider.usage(
            fromRateLimitHeaders: [
                "anthropic-ratelimit-unified-5h-utilization": "42",
                "anthropic-ratelimit-unified-5h-reset": "1760018000",
                "anthropic-ratelimit-unified-7d-utilization": "17.5",
                "anthropic-ratelimit-unified-7d-reset": "1760400000",
                "content-type": "application/json"
            ],
            planName: "Max",
            observedAt: Date(timeIntervalSince1970: 1_760_000_000)
        ))

        XCTAssertEqual(usage.session.percentUsed, 42)
        XCTAssertEqual(usage.session.resetsAt, resetsAt)
        XCTAssertTrue(usage.session.isActive)
        XCTAssertEqual(usage.weeklyAllModels.percentUsed, 17.5)
        XCTAssertEqual(usage.weeklyAllModels.resetsAt, weeklyResetsAt)
        XCTAssertEqual(usage.planName, "Max")
    }

    /// Only the `anthropic-ratelimit-*` headers are kept as the stored payload —
    /// no cookies, tokens or anything else off the response.
    func testRateLimitPayloadKeepsOnlyRateLimitHeaders() throws {
        let usage = try XCTUnwrap(ClaudeUsageProvider.usage(
            fromRateLimitHeaders: [
                "anthropic-ratelimit-unified-5h-utilization": "42",
                "set-cookie": "secret=value",
                "authorization": "Bearer nope"
            ],
            planName: nil,
            observedAt: Date()
        ))

        let payload = try XCTUnwrap(usage.rawPayload)
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: payload) as? [String: String]
        )
        XCTAssertEqual(decoded, ["anthropic-ratelimit-unified-5h-utilization": "42"])
    }

    /// Partial headers are still worth something: report the window we know and
    /// leave the other empty rather than discarding the whole reading.
    func testRateLimitHeadersWithOnlyOneWindow() throws {
        let usage = try XCTUnwrap(ClaudeUsageProvider.usage(
            fromRateLimitHeaders: ["anthropic-ratelimit-unified-7d-utilization": "60"],
            planName: nil,
            observedAt: Date()
        ))
        XCTAssertEqual(usage.weeklyAllModels.percentUsed, 60)
        XCTAssertTrue(usage.weeklyAllModels.isActive)
        XCTAssertEqual(usage.session.percentUsed, 0)
        // Absent, not "0% used" — an empty window must not read as an active one.
        XCTAssertFalse(usage.session.isActive)
    }

    /// No unified headers at all means this strategy has nothing to say, and
    /// must say so rather than inventing a 0%/0% reading.
    func testRateLimitHeadersAbsentYieldsNil() {
        XCTAssertNil(ClaudeUsageProvider.usage(
            fromRateLimitHeaders: ["content-type": "application/json"],
            planName: nil,
            observedAt: Date()
        ))
        XCTAssertNil(ClaudeUsageProvider.usage(
            fromRateLimitHeaders: [:],
            planName: nil,
            observedAt: Date()
        ))
    }

    func testRateLimitUtilizationIsClamped() throws {
        let usage = try XCTUnwrap(ClaudeUsageProvider.usage(
            fromRateLimitHeaders: [
                "anthropic-ratelimit-unified-5h-utilization": "140",
                "anthropic-ratelimit-unified-7d-utilization": "-3"
            ],
            planName: nil,
            observedAt: Date()
        ))
        XCTAssertEqual(usage.session.percentUsed, 100)
        XCTAssertEqual(usage.weeklyAllModels.percentUsed, 0)
    }

    /// The reset header has been seen as an epoch and as RFC-3339; both parse,
    /// and a small number is read as "seconds from now" rather than as a 1970
    /// timestamp that would make every window look permanently expired.
    func testResetHeaderAcceptsEpochAndISO8601() throws {
        XCTAssertEqual(
            ClaudeUsageProvider.resetDate(fromHeader: "1760018000"),
            Date(timeIntervalSince1970: 1_760_018_000)
        )
        // Built from components rather than a hand-computed epoch so the
        // expectation is readable and can't be wrong by a day's arithmetic.
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 15
        components.hour = 17
        components.minute = 9
        components.second = 59
        components.timeZone = TimeZone(identifier: "UTC")
        let expected = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: components))

        let iso = try XCTUnwrap(ClaudeUsageProvider.resetDate(fromHeader: "2026-07-15T17:09:59.777408+00:00"))
        XCTAssertEqual(iso.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1)

        let relative = try XCTUnwrap(ClaudeUsageProvider.resetDate(fromHeader: "300"))
        XCTAssertEqual(relative.timeIntervalSinceNow, 300, accuracy: 5)

        XCTAssertNil(ClaudeUsageProvider.resetDate(fromHeader: nil))
        XCTAssertNil(ClaudeUsageProvider.resetDate(fromHeader: ""))
        XCTAssertNil(ClaudeUsageProvider.resetDate(fromHeader: "not-a-date"))
    }
}
