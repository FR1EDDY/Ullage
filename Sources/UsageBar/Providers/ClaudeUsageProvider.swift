import Foundation
import Security

/// Fetches whole-account Claude usage (shared across claude.ai, Claude Code,
/// and Cowork) from the unofficial `/api/oauth/usage` endpoint, authenticated
/// with the OAuth access token Claude Code already stores locally.
///
/// The token is read only from disk/Keychain, used solely to call
/// `api.anthropic.com`, and is never logged or persisted anywhere else.
///
/// Schema discovered by inspecting a live response on 2026-07-11. The
/// response has many more fields than we use (`extra_usage`, `spend`,
/// `seven_day_opus`, etc.) — we only map what the settings panel shows:
///   - `five_hour.utilization` / `five_hour.resets_at`   → current-session meter
///   - `seven_day.utilization` / `seven_day.resets_at`   → weekly all-models meter
///   - `limits[].is_active` (kind "session" / "weekly_all") → which window is binding
/// `utilization` was observed as a 0...100 percent already, but we normalize
/// 0...1 fractions too in case that ever changes. `resets_at` is ISO-8601
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

    private struct UsageResponse: Decodable {
        struct Window: Decodable {
            let utilization: Double?
            let resetsAt: String?
            enum CodingKeys: String, CodingKey {
                case utilization
                case resetsAt = "resets_at"
            }
        }
        struct Limit: Decodable {
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
    private static let credentialsFilePath = ("~/.claude/.credentials.json" as NSString).expandingTildeInPath
    private static let keychainService = "Claude Code-credentials"

    func fetch() async -> Result<ClaudeUsage, UsageError> {
        guard let credentials = Self.readCredentials() else {
            return .failure(.missingCredentials)
        }

        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return .failure(.network(error.localizedDescription))
        }

        guard let http = response as? HTTPURLResponse else {
            return .failure(.network("No HTTP response"))
        }
        guard (200..<300).contains(http.statusCode) else {
            return .failure(.httpStatus(http.statusCode))
        }

        do {
            let decoded = try JSONDecoder().decode(UsageResponse.self, from: data)
            let sessionActive = decoded.limits?.first(where: { $0.kind == "session" })?.isActive
            let weeklyActive = decoded.limits?.first(where: { $0.kind == "weekly_all" })?.isActive
            let session = Self.window(from: decoded.fiveHour, isActiveOverride: sessionActive)
            let weekly = Self.window(from: decoded.sevenDay, isActiveOverride: weeklyActive)
            let usage = ClaudeUsage(
                planName: Self.planName(from: credentials.subscriptionType),
                session: session,
                weeklyAllModels: weekly
            )
            return .success(usage)
        } catch {
            return .failure(.decoding(error.localizedDescription))
        }
    }

    private static func window(from raw: UsageResponse.Window?, isActiveOverride: Bool?) -> UsageWindow {
        guard let raw else { return .empty }
        let percent = normalizedPercent(raw.utilization)
        let resetsAt = raw.resetsAt.flatMap(FlexibleISO8601.date(from:))
        return UsageWindow(percentUsed: percent, resetsAt: resetsAt, isActive: isActiveOverride ?? (percent > 0))
    }

    /// The endpoint has been observed returning a 0...100 percent; normalize a
    /// 0...1 fraction too, in case that ever changes server-side.
    private static func normalizedPercent(_ value: Double?) -> Double {
        guard let value else { return 0 }
        let percent = value <= 1 ? value * 100 : value
        return min(max(percent, 0), 100)
    }

    private static func planName(from subscriptionType: String?) -> String? {
        guard let subscriptionType, !subscriptionType.isEmpty else { return nil }
        return subscriptionType.prefix(1).uppercased() + subscriptionType.dropFirst()
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

/// Parses ISO-8601 timestamps with either millisecond or microsecond
/// fractional seconds and either `Z` or `+00:00`-style offsets.
enum FlexibleISO8601 {
    private static let withFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let withoutFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(from string: String) -> Date? {
        if let date = withFractional.date(from: string) {
            return date
        }
        if let date = withoutFractional.date(from: string) {
            return date
        }
        return dateByTruncatingFractionalSeconds(string)
    }

    /// `ISO8601DateFormatter` only accepts up to millisecond precision;
    /// truncate longer fractional seconds (e.g. microseconds) and retry.
    private static func dateByTruncatingFractionalSeconds(_ string: String) -> Date? {
        guard let dotRange = string.range(of: "."),
              let endIndex = string[dotRange.upperBound...].firstIndex(where: { !$0.isNumber })
        else {
            return nil
        }
        let fractional = string[dotRange.upperBound..<endIndex].prefix(3)
        let normalized = string.replacingCharacters(in: dotRange.upperBound..<endIndex, with: String(fractional))
        return withFractional.date(from: normalized)
    }
}
