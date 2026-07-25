import Foundation

/// Cursor has no official personal usage API, so this hits the internal
/// endpoint the cursor.com/settings dashboard itself calls
/// (`GET /api/usage-summary`), authenticated with the
/// `WorkosCursorSessionToken` cookie the user signs in for via
/// `UsageModel.connectCursor()` (an embedded browser login, stored in the
/// Keychain). Cursor can change this endpoint without notice, so any failure
/// (missing token, network error, schema change) is swallowed and reported as
/// "Not connected" — it must never affect the Claude side of the app.
///
/// Schema observed live on 2026-07-16:
/// ```json
/// {
///   "billingCycleEnd": "2026-08-04T21:29:55.000Z",
///   "membershipType": "pro",
///   "individualUsage": {
///     "plan": {
///       "autoPercentUsed": 5.92,
///       "apiPercentUsed": 22.71,
///       "totalPercentUsed": 8.11
///     }
///   }
/// }
/// ```
/// `autoPercentUsed` is Cursor's own ("auto"-selected) first-party models;
/// `apiPercentUsed` is named/API models; `totalPercentUsed` is the blended
/// figure the badge shows — confirmed against the Spending page, which labels
/// these "First-party models" / "API" / "Total" respectively.
///
/// **Spend is in this same response — in cents.** Verified live on 2026-07-25
/// against the dashboard's own tiles, and the arithmetic closes exactly:
/// ```
/// totalPercentUsed 17.92173913… × 34500 = 6183   (breakdown.total, $61.83)
/// autoPercentUsed  11.83666666… × 30000 = 3551   ($35.51 of a $300 budget)
/// apiPercentUsed   58.48888888… ×  4500 = 2632   ($26.32 of a  $45 budget)
///                                  3551 + 2632  = 6183 ✓
/// ```
/// Three independently-reported percentages resolve onto round dollar budgets
/// and sum to `breakdown.total` with no remainder, so `breakdown` is *spend*
/// (not a budget) and the unit is cents. `onDemand.used: 0` matched the
/// dashboard's "On-demand $0" at the same instant.
///
/// The budgets themselves ($300 / $45) are deliberately **not** hardcoded —
/// they're plan-specific, and every figure we show is read straight out of the
/// response instead of reconstructed from an assumed denominator.
actor CursorUsageProvider {
    /// Public so tests can decode sample JSON directly against this exact shape.
    struct UsageSummaryResponse: Decodable, Sendable {
        struct IndividualUsage: Decodable, Sendable {
            /// How the cycle's spend was covered. Values are US cents.
            struct Breakdown: Decodable, Sendable {
                /// Spend charged against the plan's included allowance.
                let included: Double?
                /// Spend charged against granted bonus credit.
                let bonus: Double?
                /// Total spend this cycle — the dashboard's "Total spend".
                let total: Double?
            }
            struct Plan: Decodable, Sendable {
                let autoPercentUsed: Double?
                let apiPercentUsed: Double?
                let totalPercentUsed: Double?
                /// The included allowance, in cents (Pro: 2000 = $20.00).
                let limit: Double?
                let used: Double?
                let remaining: Double?
                let breakdown: Breakdown?
            }
            /// Usage billed beyond the plan. `used` is cents; the limits are
            /// null until the user opts in to on-demand spending.
            struct OnDemand: Decodable, Sendable {
                let used: Double?
                let limit: Double?
                let remaining: Double?
                /// Whether the account will bill past its allowance at all.
                /// With this off and the allowance gone, work simply stops —
                /// which is worth knowing *before* it happens.
                let enabled: Bool?
            }
            let plan: Plan?
            let onDemand: OnDemand?
        }
        let billingCycleStart: String?
        let billingCycleEnd: String?
        let individualUsage: IndividualUsage?
    }

    /// Cursor reports money in cents. One place converts, so a stray factor of
    /// 100 can only ever be wrong here.
    static func dollars(fromCents cents: Double?) -> Double? {
        guard let cents else { return nil }
        return cents / 100
    }

    static let keychainAccount = "cursor"
    private static let usageURL = URL(string: "https://cursor.com/api/usage-summary")!
    private static let requestTimeout: TimeInterval = 15
    private static let maxAttempts = 2

    private enum AttemptOutcome {
        case success(CursorUsage)
        /// The session cookie is present but rejected (401/403) — it has
        /// expired or been revoked. Distinct from a transient failure because
        /// the only cure is signing in again, so the UI must be able to ask.
        case unauthorized
        /// A dropped packet, a server hiccup, a schema change — anything worth
        /// retrying or riding out on the last good reading.
        case retryable
    }

    init() {}

    /// One retry after a short delay covers a dropped wifi packet or a momentary
    /// server hiccup. Auth failures are *not* retried — a rejected cookie will
    /// stay rejected until the user signs in again, so we surface `.unauthorized`
    /// immediately and let the UI offer a Reconnect button.
    func fetch() async -> CursorFetchResult {
        guard let token = KeychainStore.load(account: Self.keychainAccount) else {
            return .unavailable
        }

        for attempt in 1...Self.maxAttempts {
            switch await Self.attempt(token: token) {
            case .success(let usage):
                return .success(usage)
            case .unauthorized:
                return .unauthorized
            case .retryable:
                if attempt < Self.maxAttempts {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
        return .unavailable
    }

    private static func attempt(token: String) async -> AttemptOutcome {
        var request = URLRequest(url: usageURL, timeoutInterval: requestTimeout)
        request.httpMethod = "GET"
        request.setValue("WorkosCursorSessionToken=\(token)", forHTTPHeaderField: "Cookie")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else {
            return .retryable
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            return .unauthorized
        }
        guard (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(UsageSummaryResponse.self, from: data)
        else {
            return .retryable
        }

        let plan = decoded.individualUsage?.plan
        let percent = normalizedPercent(plan?.totalPercentUsed)
        let firstPartyPercent = normalizedPercent(plan?.autoPercentUsed)
        let apiPercent = normalizedPercent(plan?.apiPercentUsed)
        let resetsAt = decoded.billingCycleEnd.flatMap(FlexibleISO8601.date(from:))
        let startsAt = decoded.billingCycleStart.flatMap(FlexibleISO8601.date(from:))
        return .success(CursorUsage(
            percentUsed: percent,
            firstPartyPercentUsed: firstPartyPercent,
            apiPercentUsed: apiPercent,
            resetsAt: resetsAt,
            startsAt: startsAt,
            cycleLabel: nil,
            totalSpend: dollars(fromCents: plan?.breakdown?.total),
            // Absent `onDemand` means the account has never opted in, which is
            // $0 spent — not "unknown". Reporting it as missing would hide the
            // reassuring half of the answer.
            onDemandSpend: dollars(fromCents: decoded.individualUsage?.onDemand?.used ?? 0),
            includedAllowance: dollars(fromCents: plan?.limit),
            includedRemaining: dollars(fromCents: plan?.remaining),
            onDemandEnabled: decoded.individualUsage?.onDemand?.enabled,
            observedAt: Date(),
            rawPayload: data
        ))
    }

    /// Non-finite input is treated as no reading — see the note on
    /// `ClaudeUsageProvider.normalizedPercent`: a clamp doesn't clamp NaN, and
    /// a NaN percentage eventually reaches an `Int(...)` conversion that traps.
    static func normalizedPercent(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 0 }
        return min(max(value, 0), 100)
    }
}

/// Persists the last Cursor reading across launches, so a cold start shows the
/// last real number instead of "Not connected" while the first poll is in
/// flight. No secret is stored here — the session cookie stays in the Keychain.
enum CursorUsageCache {
    private static let readingKey = "cursor.lastReading"

    static func loadReading() -> CursorUsage? {
        guard let data = UserDefaults.standard.data(forKey: readingKey) else { return nil }
        return try? JSONDecoder().decode(CursorUsage.self, from: data)
    }

    static func saveReading(_ usage: CursorUsage) {
        guard let data = try? JSONEncoder().encode(usage) else { return }
        UserDefaults.standard.set(data, forKey: readingKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: readingKey)
    }
}
