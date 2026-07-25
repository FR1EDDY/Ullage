import Foundation
import Security

/// Fetches whole-account Claude usage (shared across claude.ai, Claude Code,
/// and Cowork) via one of two unofficial paths:
///   - **Cookie** (in-app sign-in): the same two-step call the claude.ai
///     settings page itself makes — `GET /api/organizations` to find the
///     account's org id, then `GET /api/organizations/{id}/usage` — both
///     authenticated with an ordinary `sessionKey` browser session cookie.
///     This is what `UsageModel.connectClaude()` sets up. A real OAuth
///     "connect an app" flow was tried first and abandoned: claude.ai's
///     authorize endpoint requires `arkose_session_token` and
///     `client_attestation` fields that only Anthropic's own signed clients
///     can produce, so no third-party app can complete it (confirmed live,
///     2026-07-15 — see project memory).
///   - **Bearer** (fallback): the OAuth access token Claude Code already
///     stores locally, read only from disk/Keychain and never persisted
///     elsewhere. Used automatically when no cookie has been set up, so
///     existing Claude Code users need do nothing.
///
/// Schema discovered by inspecting a live response on 2026-07-11. The
/// response has many more fields than we use (`extra_usage`, `spend`,
/// `seven_day_opus`, etc.) — we only map what the settings panel shows:
///   - `five_hour.utilization` / `five_hour.resets_at`   → current-session meter
///   - `seven_day.utilization` / `seven_day.resets_at`   → weekly all-models meter
///   - `limits[].is_active` (kind "session" / "weekly_all") → which window is binding
/// `utilization` is always a 0...100 percent already (not a 0...1 fraction —
/// confirmed live, since guessing between the two misreads 1% as 100%).
/// `resets_at` is ISO-8601
/// with microsecond fractional seconds (e.g. "2026-07-11T17:50:00.022049+00:00"),
/// which `ISO8601DateFormatter` can't parse directly, so `FlexibleISO8601`
/// truncates to millisecond precision before retrying.
actor ClaudeUsageProvider {
    private struct CredentialsFile: Decodable {
        struct OAuth: Decodable {
            let accessToken: String
            let subscriptionType: String?
        }
        let claudeAiOauth: OAuth
    }

    /// Public so tests can decode sample JSON directly against this exact
    /// shape — the surface most likely to silently break if Anthropic tweaks
    /// the response.
    struct UsageResponse: Decodable, Sendable {
        struct Window: Decodable, Sendable {
            let utilization: Double?
            let resetsAt: String?
            enum CodingKeys: String, CodingKey {
                case utilization
                case resetsAt = "resets_at"
            }
        }
        struct Limit: Decodable, Sendable {
            let kind: String?
            let isActive: Bool?
            enum CodingKeys: String, CodingKey {
                case kind
                case isActive = "is_active"
            }
        }
        let fiveHour: Window?
        let sevenDay: Window?
        let limits: [Limit]?
        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case limits
        }
    }

    private struct Credentials {
        let accessToken: String
        let subscriptionType: String?
    }

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let organizationsURL = URL(string: "https://claude.ai/api/organizations")!
    /// `uuid` comes off the wire, so this stays a plain optional rather than a
    /// force-unwrap — a malformed org id should degrade to a decoding failure,
    /// not crash the app.
    private static func organizationUsageURL(_ uuid: String) -> URL? {
        URL(string: "https://claude.ai/api/organizations/\(uuid)/usage")
    }
    private static let credentialsFilePath = ("~/.claude/.credentials.json" as NSString).expandingTildeInPath
    private static let keychainService = "Claude Code-credentials"
    private static let requestTimeout: TimeInterval = 15
    private static let maxAttempts = 3

    /// Hard floor between network calls, enforced here rather than in the
    /// caller so that no path — timer tick, app launch, or a user leaning on
    /// the Refresh button — can push the endpoint faster than this. Requests
    /// inside the window are served from `cached`.
    private static let minimumRequestInterval: TimeInterval = 60

    /// How long a successful reading stays usable. The endpoint describes a
    /// 5-hour and a 7-day window, so a reading minutes old is still accurate
    /// to well under a percent; refetching faster buys nothing and is what
    /// got us rate-limited.
    private static let cacheLifetime: TimeInterval = 120

    /// Past this age a stored reading is no longer worth showing during a
    /// cooldown — the 5-hour window it describes has certainly turned over, so
    /// it would be a confidently-drawn meter of a session that no longer exists.
    private static let maximumServableAge: TimeInterval = 86_400

    private var cached: ClaudeUsage?
    private var nextRequestAllowedAt: Date?

    private enum AttemptResult {
        case success(ClaudeUsage)
        case failure(UsageError, retryAfter: TimeInterval?)
    }

    init() {
        self.cached = ClaudeUsageCache.loadReading()
        self.nextRequestAllowedAt = ClaudeUsageCache.loadCooldown()
    }

    /// When the next network call will be permitted, so the UI can show an
    /// honest countdown on the Refresh button instead of offering a button that
    /// silently does nothing.
    func retryAvailableAt() -> Date? {
        guard let nextRequestAllowedAt, nextRequestAllowedAt > Date() else { return nil }
        return nextRequestAllowedAt
    }

    private func beginCooldown(_ interval: TimeInterval) {
        let until = Date().addingTimeInterval(interval)
        nextRequestAllowedAt = until
        ClaudeUsageCache.saveCooldown(until)
    }

    /// Serves the cached reading when one is fresh or when we're inside a
    /// cooldown, so the endpoint sees at most one request per
    /// `minimumRequestInterval` no matter how often this is called — and,
    /// because the cooldown is persisted, no matter how often the *app* is
    /// relaunched. That last part matters more than it looks: the floor used to
    /// live only in memory, so a rebuild-and-run cycle fired an immediate
    /// unthrottled request every time, and a burst of launches is what tripped
    /// the limit in the first place.
    ///
    /// Genuinely transient failures (server hiccup, dropped connection) are
    /// retried with backoff. Rate limits are *not* — a 429 means "you are
    /// already asking too often", so retrying it in-process is the one thing
    /// guaranteed to make it worse. It ends the fetch and starts a cooldown
    /// instead.
    func fetch() async -> Result<ClaudeUsage, UsageError> {
        guard let method = Self.resolveAuthMethod() else {
            return .failure(.missingCredentials)
        }

        if let cached, Date().timeIntervalSince(cached.observedAt) < Self.cacheLifetime {
            return .success(cached)
        }
        if let nextRequestAllowedAt, Date() < nextRequestAllowedAt {
            if let cached, Date().timeIntervalSince(cached.observedAt) < Self.maximumServableAge {
                return .success(cached)
            }
            return .failure(.coolingDown(retryAfter: nextRequestAllowedAt.timeIntervalSinceNow))
        }

        for attempt in 1...Self.maxAttempts {
            beginCooldown(Self.minimumRequestInterval)

            switch await Self.attempt(method: method) {
            case .success(let usage):
                cached = usage
                ClaudeUsageCache.saveReading(usage)
                return .success(usage)
            case .failure(let error, let retryAfter):
                if case .rateLimited = error {
                    // Wait out the server's own hint when it gives a usable
                    // one, otherwise sit out the standard cooldown.
                    beginCooldown(max(retryAfter ?? 0, Self.minimumRequestInterval))
                    return .failure(error)
                }
                let isLastAttempt = attempt == Self.maxAttempts
                guard !isLastAttempt, let delay = Self.retryDelay(for: error, retryAfter: retryAfter, attempt: attempt) else {
                    return .failure(error)
                }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        return .failure(.network("Retry attempts exhausted"))
    }

    private enum AuthMethod {
        case cookie(sessionKey: String)
        case bearer(Credentials)
    }

    /// Prefers the cookie the user set up via in-app sign-in; falls back to a
    /// Claude Code / desktop token on disk. Both reads are local (Keychain or
    /// file), so this never blocks on the network.
    private static func resolveAuthMethod() -> AuthMethod? {
        if let sessionKey = ClaudeCookieStore.loadSessionKey() {
            return .cookie(sessionKey: sessionKey)
        }
        if let credentials = readCredentials() {
            return .bearer(credentials)
        }
        return nil
    }

    private static func attempt(method: AuthMethod) async -> AttemptResult {
        switch method {
        case .bearer(let credentials):
            return await attemptBearer(credentials: credentials)
        case .cookie(let sessionKey):
            return await attemptCookie(sessionKey: sessionKey)
        }
    }

    private static func attemptBearer(credentials: Credentials) async -> AttemptResult {
        var request = URLRequest(url: usageURL, timeoutInterval: requestTimeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return .failure(.network(error.localizedDescription), retryAfter: nil)
        }

        guard let http = response as? HTTPURLResponse else {
            return .failure(.network("No HTTP response"), retryAfter: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            // The endpoint answers 429 with `Retry-After: 0`, which is not a
            // real instruction to retry immediately — it carries no timing
            // information at all. Treat a non-positive value as absent so it
            // can't collapse the backoff to zero.
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                .flatMap(TimeInterval.init)
                .flatMap { $0 > 0 ? $0 : nil }
            if http.statusCode == 429 {
                return .failure(.rateLimited(retryAfter: retryAfter), retryAfter: retryAfter)
            }
            return .failure(.httpStatus(http.statusCode), retryAfter: retryAfter)
        }

        do {
            let decoded = try JSONDecoder().decode(UsageResponse.self, from: data)
            let sessionActive = decoded.limits?.first(where: { $0.kind == "session" })?.isActive
            let weeklyActive = decoded.limits?.first(where: { $0.kind == "weekly_all" })?.isActive
            let session = window(from: decoded.fiveHour, isActiveOverride: sessionActive)
            let weekly = window(from: decoded.sevenDay, isActiveOverride: weeklyActive)
            let usage = ClaudeUsage(
                planName: planName(from: credentials.subscriptionType),
                session: session,
                weeklyAllModels: weekly,
                observedAt: Date()
            )
            return .success(usage)
        } catch {
            return .failure(.decoding(error.localizedDescription), retryAfter: nil)
        }
    }

    /// The in-app sign-in path. `claude.ai`'s own settings page authenticates
    /// this exact two-step call with nothing but the ordinary session cookie —
    /// it's a plain authenticated page load, not a third-party "connect an
    /// app" grant, so none of the bot-attestation machinery that blocks OAuth
    /// applies here.
    private static func attemptCookie(sessionKey: String) async -> AttemptResult {
        guard let orgUUID = await resolveOrganizationUUID(sessionKey: sessionKey) else {
            // Either the lookup failed transiently or the cookie is dead. We
            // can't tell apart from here, but treating it as expired is the
            // safe default: it surfaces a Reconnect prompt instead of retrying
            // silently forever against a cookie that may never work again.
            return .failure(.sessionExpired, retryAfter: nil)
        }

        guard let usageURL = organizationUsageURL(orgUUID) else {
            return .failure(.decoding("Malformed organization usage URL"), retryAfter: nil)
        }
        var request = URLRequest(url: usageURL, timeoutInterval: requestTimeout)
        request.httpMethod = "GET"
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return .failure(.network(error.localizedDescription), retryAfter: nil)
        }

        guard let http = response as? HTTPURLResponse else {
            return .failure(.network("No HTTP response"), retryAfter: nil)
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            return .failure(.sessionExpired, retryAfter: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                .flatMap(TimeInterval.init)
                .flatMap { $0 > 0 ? $0 : nil }
            if http.statusCode == 429 {
                return .failure(.rateLimited(retryAfter: retryAfter), retryAfter: retryAfter)
            }
            return .failure(.httpStatus(http.statusCode), retryAfter: retryAfter)
        }

        do {
            let decoded = try JSONDecoder().decode(UsageResponse.self, from: data)
            let sessionActive = decoded.limits?.first(where: { $0.kind == "session" })?.isActive
            let weeklyActive = decoded.limits?.first(where: { $0.kind == "weekly_all" })?.isActive
            let usage = ClaudeUsage(
                // The org/usage endpoint doesn't echo the plan tier the way the
                // Claude Code credentials file does; leaving it nil just hides
                // the plan badge rather than showing something wrong.
                planName: nil,
                session: window(from: decoded.fiveHour, isActiveOverride: sessionActive),
                weeklyAllModels: window(from: decoded.sevenDay, isActiveOverride: weeklyActive),
                observedAt: Date()
            )
            return .success(usage)
        } catch {
            return .failure(.decoding(error.localizedDescription), retryAfter: nil)
        }
    }

    /// The org id is stable for an account, so this round trip only happens
    /// once — right after sign-in — and every later poll goes straight to the
    /// usage endpoint. Failure here (bad cookie, network hiccup) is treated as
    /// an expired session by the caller.
    private static func resolveOrganizationUUID(sessionKey: String) async -> String? {
        if let cached = ClaudeCookieStore.loadOrganizationUUID() {
            return cached
        }
        var request = URLRequest(url: organizationsURL, timeoutInterval: requestTimeout)
        request.httpMethod = "GET"
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let organizations = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let uuid = organizations.first?["uuid"] as? String
        else {
            return nil
        }
        ClaudeCookieStore.saveOrganizationUUID(uuid)
        return uuid
    }

    /// How long to wait before retrying, or `nil` if this error shouldn't be
    /// retried at all. Network blips and server errors get a short fixed
    /// backoff since those usually clear within seconds. Rate limits never
    /// reach here — `fetch` ends the attempt loop on a 429 rather than
    /// retrying into a limit we've already tripped.
    private static func retryDelay(for error: UsageError, retryAfter: TimeInterval?, attempt: Int) -> TimeInterval? {
        switch error {
        case .network:
            return backoffDelay(for: attempt)
        case .httpStatus(let code):
            guard (500...599).contains(code) else { return nil }
            return retryAfter ?? backoffDelay(for: attempt)
        case .rateLimited, .coolingDown, .missingCredentials, .decoding, .sessionExpired:
            return nil
        }
    }

    /// 1s then 3s — short enough to recover within the same refresh cycle,
    /// long enough to not hammer a service that just rate-limited us.
    private static func backoffDelay(for attempt: Int) -> TimeInterval {
        attempt == 1 ? 1 : 3
    }

    static func window(from raw: UsageResponse.Window?, isActiveOverride: Bool?) -> UsageWindow {
        guard let raw else { return .empty }
        let percent = normalizedPercent(raw.utilization)
        let resetsAt = raw.resetsAt.flatMap(FlexibleISO8601.date(from:))
        return UsageWindow(percentUsed: percent, resetsAt: resetsAt, isActive: isActiveOverride ?? (percent > 0))
    }

    /// The endpoint always returns a 0...100 percent (confirmed live: 1.0 means
    /// 1% used, not a 0...1 fraction). Guessing at fraction-vs-percent by
    /// checking `value <= 1` misreads exactly 1% as 100%, so just clamp.
    static func normalizedPercent(_ value: Double?) -> Double {
        guard let value else { return 0 }
        return min(max(value, 0), 100)
    }

    static func planName(from subscriptionType: String?) -> String? {
        guard let subscriptionType, !subscriptionType.isEmpty else { return nil }
        return subscriptionType.prefix(1).uppercased() + subscriptionType.dropFirst()
    }

    /// Whether the app can obtain Claude usage at all, from either source — a
    /// cookie the user set up via in-app sign-in, or a Claude Code / desktop
    /// credential on disk. Drives the choice between a "Connect Claude"
    /// call-to-action and the meters.
    static func hasAnyCredentials() -> Bool {
        ClaudeCookieStore.loadSessionKey() != nil || readCredentials() != nil
    }

    /// Whether the user signed in *through this app* (as opposed to us borrowing
    /// a Claude Code token). Only then is there something for us to "Sign out" of.
    static func hasStoredLogin() -> Bool {
        ClaudeCookieStore.loadSessionKey() != nil
    }

    private static func readCredentials() -> Credentials? {
        readCredentialsFromFile() ?? readCredentialsFromKeychain()
    }

    private static func readCredentialsFromFile() -> Credentials? {
        guard let data = FileManager.default.contents(atPath: credentialsFilePath) else {
            return nil
        }
        return decodeCredentials(data)
    }

    private static func readCredentialsFromKeychain() -> Credentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return decodeCredentials(data)
    }

    private static func decodeCredentials(_ data: Data) -> Credentials? {
        guard let decoded = try? JSONDecoder().decode(CredentialsFile.self, from: data) else {
            return nil
        }
        return Credentials(
            accessToken: decoded.claudeAiOauth.accessToken,
            subscriptionType: decoded.claudeAiOauth.subscriptionType
        )
    }
}

/// The claude.ai session cookie and cached organization id for the in-app
/// sign-in path. Stored separately: the cookie is sensitive (Keychain), the
/// org id isn't — it's just a cache of a value that never changes for an
/// account, safe to lose and cheaply re-fetched.
enum ClaudeCookieStore {
    private static let keychainAccount = "claude-session"
    private static let orgUUIDKey = "claude.orgUUID"

    static func loadSessionKey() -> String? {
        KeychainStore.load(account: keychainAccount)
    }

    static func saveSessionKey(_ value: String) {
        KeychainStore.save(value, account: keychainAccount)
    }

    static func clearSessionKey() {
        KeychainStore.delete(account: keychainAccount)
        clearOrganizationUUID()
    }

    static func loadOrganizationUUID() -> String? {
        UserDefaults.standard.string(forKey: orgUUIDKey)
    }

    static func saveOrganizationUUID(_ uuid: String) {
        UserDefaults.standard.set(uuid, forKey: orgUUIDKey)
    }

    static func clearOrganizationUUID() {
        UserDefaults.standard.removeObject(forKey: orgUUIDKey)
    }
}

/// The last Claude reading and the earliest time we may call the endpoint
/// again, persisted across launches.
///
/// Both used to be in-memory only, which made the request floor a fiction: it
/// reset on every launch, so quitting and reopening (or a run of rebuilds)
/// bypassed it entirely. Persisting them also means a cold start renders the
/// last real numbers, dated, rather than "Loading…" forever if that launch's
/// first fetch happens to fail.
///
/// Only the two usage percentages and their reset dates are stored — never the
/// OAuth token, which stays in the Keychain.
enum ClaudeUsageCache {
    private static let readingKey = "claude.lastReading"
    private static let cooldownKey = "claude.nextRequestAllowedAt"

    static func loadReading() -> ClaudeUsage? {
        guard let data = UserDefaults.standard.data(forKey: readingKey) else { return nil }
        return try? JSONDecoder().decode(ClaudeUsage.self, from: data)
    }

    static func saveReading(_ usage: ClaudeUsage) {
        guard let data = try? JSONEncoder().encode(usage) else { return }
        UserDefaults.standard.set(data, forKey: readingKey)
    }

    static func loadCooldown() -> Date? {
        let stored = UserDefaults.standard.double(forKey: cooldownKey)
        guard stored > 0 else { return nil }
        return Date(timeIntervalSince1970: stored)
    }

    static func saveCooldown(_ date: Date) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: cooldownKey)
    }
}
