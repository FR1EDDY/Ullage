import Foundation

/// The four token classes Anthropic bills separately. Kept as one struct so
/// nothing can price three of them and quietly forget the fourth.
struct TokenCounts: Equatable, Sendable, Codable {
    var input: Int = 0
    var output: Int = 0
    /// Tokens written to the 5-minute ephemeral cache (billed at 1.25× input).
    var cacheWrite5m: Int = 0
    /// Tokens written to the 1-hour ephemeral cache (billed at 2× input).
    var cacheWrite1h: Int = 0
    /// Tokens served from cache (billed at 0.1× input).
    var cacheRead: Int = 0

    /// What the UI means by "tokens" — everything that crossed the wire.
    var total: Int { input + output + cacheWrite5m + cacheWrite1h + cacheRead }

    static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheWrite5m: lhs.cacheWrite5m + rhs.cacheWrite5m,
            cacheWrite1h: lhs.cacheWrite1h + rhs.cacheWrite1h,
            cacheRead: lhs.cacheRead + rhs.cacheRead
        )
    }

    static func += (lhs: inout TokenCounts, rhs: TokenCounts) {
        lhs = lhs + rhs
    }
}

/// One API request, as recovered from a Claude Code log line.
///
/// `identity` is the dedupe key. Claude Code writes an assistant record more
/// than once per request (streaming updates, and again when a session is
/// resumed into a new file), so counting lines instead of distinct requests
/// roughly *doubles* every figure — confirmed against real logs on 2026-07-25.
/// `Codable` so parsed transcripts survive a relaunch: re-reading tens of
/// megabytes of JSONL costs seconds, and paying that on every launch would
/// burn CPU and battery to rediscover something that cannot have changed.
struct CostRecord: Equatable, Sendable, Codable {
    let identity: String
    let timestamp: Date
    let model: String
    let tokens: TokenCounts
    /// The working directory the request was made from, straight off the log
    /// line. Taken from `cwd` rather than decoded from the transcript folder
    /// name, which mangles any project whose name contains a hyphen.
    let project: String?

    /// `project` defaults to `nil` so a record can be built without one — older
    /// transcripts and malformed lines genuinely lack a `cwd`, and that has to
    /// stay expressible rather than forcing a placeholder that would then be
    /// aggregated as if it were a real project.
    init(identity: String, timestamp: Date, model: String, tokens: TokenCounts, project: String? = nil) {
        self.identity = identity
        self.timestamp = timestamp
        self.model = model
        self.tokens = tokens
        self.project = project
    }
}

/// What prompt caching actually cost or saved, in dollars.
///
/// This is the bill recomputed, not a projection: reads are billed at 0.1× the
/// input rate (a saving), writes at 1.25× for the 5-minute TTL and 2× for the
/// one-hour TTL (a premium). Whether caching is winning is simply whether the
/// savings exceed the premium — and it can genuinely go either way, which is
/// why it's worth stating rather than assuming.
struct CacheEconomics: Equatable, Sendable {
    /// Dollars saved by tokens served from cache instead of billed as input.
    var savedByReads: Double = 0
    /// Extra dollars paid for writing tokens into the cache in the first place.
    var premiumOnWrites: Double = 0
    var readTokens: Int = 0
    var writeTokens5m: Int = 0
    var writeTokens1h: Int = 0

    /// Positive means caching is paying for itself.
    var net: Double { savedByReads - premiumOnWrites }
    var writeTokens: Int { writeTokens5m + writeTokens1h }

    /// How many times the average cached token was read back. The break-even
    /// point is the write premium divided by the per-read saving: about **0.28**
    /// for the 5-minute TTL and **1.11** for the one-hour TTL. Below that, the
    /// write cost more than the reads recovered.
    var readsPerWrittenToken: Double? {
        guard writeTokens > 0 else { return nil }
        return Double(readTokens) / Double(writeTokens)
    }
}

/// One project's share of the bill. The unit people actually think in — "what
/// is this repo costing me" is a question the per-model view can't answer.
struct ProjectCost: Equatable, Sendable, Identifiable {
    let name: String
    let cost: Double
    let requestCount: Int

    var id: String { name }
}

/// The same tokens, priced at a different model's rate.
///
/// Deliberately **a number, not a recommendation.** We can see tokens and cost;
/// we can never see whether the cheaper model would have produced an acceptable
/// answer, or needed three attempts to do it. Presenting the arithmetic and
/// stopping there is the only honest version of this.
struct ModelAlternative: Equatable, Sendable, Identifiable {
    let model: String
    let cost: Double

    var id: String { model }
}

/// One day's spend, for the bar chart.
struct DailyCost: Equatable, Sendable, Identifiable {
    /// Start of the day in the user's own calendar — see `CostSummary`.
    let day: Date
    let cost: Double
    let tokens: Int

    var id: Date { day }
}

/// Everything the Cost section of the popover renders.
///
/// **On time zones.** Every timestamp is parsed as an absolute instant (UTC),
/// exactly like the rest of the app. Bucketing into *days* happens against the
/// user's own calendar, because "what did I spend today" is inherently a local
/// question — a 9pm session in UTC-8 belongs to that person's today, not to
/// tomorrow. That bucketing is the display boundary, and nothing below it
/// touches a local time zone.
struct CostSummary: Equatable, Sendable {
    var today: Double = 0
    var last30Days: Double = 0
    var todayTokens: TokenCounts = TokenCounts()
    var last30DaysTokens: TokenCounts = TokenCounts()
    /// Highest-spend model over the 30-day window, with its share of the total.
    var topModel: String?
    var topModelCost: Double = 0
    /// Ascending, one entry per day that had usage.
    var daily: [DailyCost] = []
    /// Models we found usage for but have no price for. Surfaced in the UI as
    /// "unpriced" — reporting them as $0 would be a quiet lie, and the whole
    /// point of this feature is a cost number you can trust.
    var unpricedModels: [String] = []
    /// Requests attributed to those unpriced models, so the UI can say how much
    /// of the picture is missing rather than just that something is.
    var unpricedRequests: Int = 0
    var requestCount: Int = 0
    /// What caching did to the bill over the 30-day window.
    var cache: CacheEconomics = CacheEconomics()
    /// Highest-spend projects first.
    var byProject: [ProjectCost] = []
    /// The window's whole token count re-priced at other models' rates.
    var alternatives: [ModelAlternative] = []
    var observedAt: Date = .distantPast

    /// True when there's genuinely nothing to show — distinct from "$0.00
    /// spent today", which is a real and useful answer.
    var isEmpty: Bool { requestCount == 0 && unpricedRequests == 0 }
}
