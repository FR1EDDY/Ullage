import Foundation

/// A single usage window (e.g. the 5-hour session limit, or the weekly
/// all-models limit) normalized to a 0...100 percentage.
struct UsageWindow: Equatable, Codable, Sendable {
    var percentUsed: Double
    var resetsAt: Date?
    var isActive: Bool

    init(percentUsed: Double, resetsAt: Date?, isActive: Bool) {
        self.percentUsed = percentUsed
        self.resetsAt = resetsAt
        self.isActive = isActive
    }

    static let empty = UsageWindow(percentUsed: 0, resetsAt: nil, isActive: false)
}

/// Whole-account Claude usage — shared across claude.ai, Claude Code, and Cowork.
/// `Codable` because the last reading outlives the process: it's persisted so a
/// cold start can show real (dated) numbers instead of an indefinite "Loading…"
/// when the first fetch of the new launch fails.
struct ClaudeUsage: Equatable, Codable, Sendable {
    var planName: String?
    var session: UsageWindow
    var weeklyAllModels: UsageWindow
    /// When these numbers actually came off the wire. A reading can be served
    /// from the provider's cache, so this — not the time it was handed to the
    /// UI — is what "Updated Xs ago" has to report.
    var observedAt: Date

    init(
        planName: String?,
        session: UsageWindow,
        weeklyAllModels: UsageWindow,
        observedAt: Date
    ) {
        self.planName = planName
        self.session = session
        self.weeklyAllModels = weeklyAllModels
        self.observedAt = observedAt
    }
}

/// Cursor usage for the current billing cycle. `Codable` for the same reason
/// `ClaudeUsage` is: the last good reading is retained through transient poll
/// failures (and across launches) so a single dropped request doesn't flip the
/// UI to "Not connected" when we still have a perfectly good recent number.
struct CursorUsage: Equatable, Codable, Sendable {
    /// The blended figure across both categories below — what Cursor's own
    /// badge and top-line "Total" percentage show.
    var percentUsed: Double
    /// Usage against Cursor's own ("auto"-selected) first-party models.
    var firstPartyPercentUsed: Double
    /// Usage against named/API models.
    var apiPercentUsed: Double
    var resetsAt: Date?
    var cycleLabel: String?
    /// When this reading came off the wire, used to decide when a retained
    /// value has aged past the point of being worth showing.
    var observedAt: Date

    init(
        percentUsed: Double,
        firstPartyPercentUsed: Double,
        apiPercentUsed: Double,
        resetsAt: Date?,
        cycleLabel: String?,
        observedAt: Date
    ) {
        self.percentUsed = percentUsed
        self.firstPartyPercentUsed = firstPartyPercentUsed
        self.apiPercentUsed = apiPercentUsed
        self.resetsAt = resetsAt
        self.cycleLabel = cycleLabel
        self.observedAt = observedAt
    }
}

enum UsageError: Error, LocalizedError, Equatable, Sendable {
    case missingCredentials
    /// The usage endpoint is rate-limiting us — a 429 that genuinely came off
    /// the wire. `retryAfter` is the server's `Retry-After` in seconds when it
    /// sends a usable one — in practice it sends `0`, which is normalized away
    /// to `nil` rather than taken literally as "retry immediately".
    case rateLimited(retryAfter: TimeInterval?)
    /// We suppressed the request ourselves: the provider's minimum interval
    /// hadn't elapsed and there was no cached reading to serve. Distinct from
    /// `rateLimited` because no request was made and the server said nothing —
    /// conflating the two let a self-imposed cooldown masquerade as the
    /// endpoint rejecting us, and compounded the caller's backoff for it.
    case coolingDown(retryAfter: TimeInterval)
    /// The stored claude.ai session cookie was rejected (401/403) — expired or
    /// revoked. Distinct from the other failures because the fix is always the
    /// same and always the user's to make: sign in again.
    case sessionExpired
    case httpStatus(Int)
    case decoding(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Not signed in to Claude Code"
        case .rateLimited:
            return "Claude is rate-limiting usage checks"
        case .coolingDown:
            return "Waiting before re-checking Claude usage"
        case .sessionExpired:
            return "Claude session expired"
        case .httpStatus(let code):
            return "Claude usage request failed (\(code))"
        case .decoding(let detail):
            return "Couldn't parse Claude usage response (\(detail))"
        case .network(let detail):
            return detail
        }
    }
}

/// What one Cursor fetch tells the model. Mirrors the three states the UI can
/// meaningfully act on: show numbers, ask the user to reconnect, or quietly ride
/// out a blip on the last good reading.
enum CursorFetchResult: Sendable {
    case success(CursorUsage)
    case unauthorized
    case unavailable
}
