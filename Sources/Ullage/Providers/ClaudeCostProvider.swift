import Foundation

/// Reconstructs what Claude Code actually cost, from the JSONL transcripts it
/// already writes to `~/.claude/projects/**/*.jsonl`. No network, no API — this
/// works offline and on a rate-limited account, which is precisely when a usage
/// app is least able to tell you anything else.
///
/// Schema observed live on 2026-07-25. An assistant line carries:
/// ```json
/// {
///   "type": "assistant",
///   "timestamp": "2026-07-23T22:48:58.627Z",
///   "requestId": "req_011CdKoeec5JKH86AJdDQ1Qq",
///   "message": {
///     "id": "msg_011CdKoeh7PT5bW9G31R5esH",
///     "model": "claude-opus-4-8",
///     "usage": {
///       "input_tokens": 2, "output_tokens": 338,
///       "cache_creation_input_tokens": 9812, "cache_read_input_tokens": 12611,
///       "cache_creation": { "ephemeral_1h_input_tokens": 9812, "ephemeral_5m_input_tokens": 0 }
///     }
///   }
/// }
/// ```
///
/// Three things about that shape drive the whole implementation:
///   - **Records repeat.** The same `message.id` + `requestId` pair appears
///     multiple times — consecutive streaming writes, and again when a session
///     is resumed into a new file. Every figure here is deduped on that pair;
///     without it, costs come out roughly double.
///   - **Cache writes are split by TTL.** `cache_creation` breaks the total
///     into 1-hour and 5-minute buckets, which bill at 2× and 1.25× the input
///     rate respectively. Pricing the lump `cache_creation_input_tokens` at one
///     rate would misprice every cached session.
///   - **`<synthetic>` is not a model.** It marks locally-generated messages
///     that never hit the API, and is excluded rather than counted as unpriced.
actor ClaudeCostProvider {
    /// Identifies a file version cheaply. If both match, the transcript is
    /// byte-for-byte what we already parsed.
    private struct Fingerprint: Equatable, Codable {
        let size: Int
        let modifiedAt: Date
    }

    private struct CachedFile: Codable {
        let fingerprint: Fingerprint
        let records: [CostRecord]
    }

    /// Wraps the cache so a change to `CostRecord`'s shape can be detected and
    /// the whole thing rebuilt, rather than silently decoding into records
    /// missing whatever field was just added. Bump on any such change.
    private struct CacheFile: Codable {
        static let currentVersion = 2
        var version: Int = CacheFile.currentVersion
        var files: [String: CachedFile]
    }

    static let logsDirectory = ("~/.claude/projects" as NSString).expandingTildeInPath

    /// How far back the UI looks. A few days of slack over the 30 days we show,
    /// so a request right on the boundary isn't lost to clock skew.
    static let window: TimeInterval = 35 * 24 * 60 * 60

    /// Locally-generated messages that never reached the API.
    private static let syntheticModel = "<synthetic>"

    /// Parsed records per file, keyed by path. A transcript whose size and
    /// mtime are unchanged is served from here, so in practice only the session
    /// you're actively using is ever re-read.
    ///
    /// Deliberately caches *records*, not costs: a corrected price table then
    /// re-prices instantly with no re-parse.
    ///
    /// Persisted (see `cacheURL`) because the numbers are stark — a full parse
    /// of a heavy user's transcript tree is ~8 seconds of CPU, while re-reading
    /// this cache is ~30 ms. Paying the former on every launch to rediscover
    /// records that provably haven't changed is exactly the kind of thing that
    /// makes an app feel heavy.
    private var cache: [String: CachedFile] = [:]
    private var cacheLoaded = false
    private var cacheDirty = false

    private let directory: String
    private let pricing: ModelPricing
    private let calendar: Calendar
    private let cacheURL: URL?

    /// Everything is injectable so tests run against a fixture tree, in a fixed
    /// time zone, with their own cache file — never the user's real logs.
    init(
        directory: String = ClaudeCostProvider.logsDirectory,
        pricing: ModelPricing = .shared,
        calendar: Calendar = .current,
        cacheURL: URL? = ClaudeCostProvider.defaultCacheURL()
    ) {
        self.directory = directory
        self.pricing = pricing
        self.calendar = calendar
        self.cacheURL = cacheURL
    }

    static func defaultCacheURL() -> URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("Ullage", isDirectory: true)
        .appendingPathComponent("cost-cache.json", isDirectory: false)
    }

    /// Rebuilds the cost picture. Cheap after the first call — only files that
    /// changed are re-read.
    func summary(now: Date = Date()) -> CostSummary {
        let cutoff = now.addingTimeInterval(-Self.window)
        let records = loadRecords(since: cutoff)
        persistCacheIfNeeded()
        return Self.summarize(records: records, now: now, pricing: pricing, calendar: calendar)
    }

    // MARK: - Persisted parse cache

    private func loadCacheIfNeeded() {
        guard !cacheLoaded else { return }
        cacheLoaded = true
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL) else { return }
        // A cache we can't read is a cache we rebuild — never an error the user
        // hears about. Same for one written by an older schema: the version gate
        // costs one slow re-parse and buys certainty that every record has the
        // fields the current code expects.
        guard let decoded = try? JSONDecoder().decode(CacheFile.self, from: data),
              decoded.version == CacheFile.currentVersion
        else { return }
        cache = decoded.files
    }

    private func persistCacheIfNeeded() {
        guard cacheDirty, let cacheURL else { return }
        cacheDirty = false
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(CacheFile(files: cache)) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    // MARK: - Reading

    /// Every record from every transcript touched inside the window, deduped.
    ///
    /// Files are filtered by modification date before being opened: a project
    /// you last worked on in March can't contain a request from this week, so
    /// there's no reason to read it at all. That check alone is what keeps this
    /// bounded as the transcript directory grows without limit.
    private func loadRecords(since cutoff: Date) -> [CostRecord] {
        loadCacheIfNeeded()
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: URL(fileURLWithPath: directory),
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var livePaths: Set<String> = []
        var deduped: [String: CostRecord] = [:]

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modifiedAt = values.contentModificationDate,
                  let size = values.fileSize,
                  modifiedAt >= cutoff
            else { continue }

            let path = url.path
            livePaths.insert(path)
            let fingerprint = Fingerprint(size: size, modifiedAt: modifiedAt)

            let records: [CostRecord]
            if let cached = cache[path], cached.fingerprint == fingerprint {
                records = cached.records
            } else {
                records = Self.parse(fileAt: url)
                cache[path] = CachedFile(fingerprint: fingerprint, records: records)
                cacheDirty = true
            }

            // Dedupe across files as well as within them: resuming a session
            // copies earlier turns into the new transcript, so the same request
            // legitimately appears in two places.
            for record in records where record.timestamp >= cutoff {
                deduped[record.identity] = record
            }
        }

        // Drop cache entries for files that aged out or were deleted, so this
        // can't grow without bound across a long-running launch.
        if cache.count != livePaths.count {
            cache = cache.filter { livePaths.contains($0.key) }
            cacheDirty = true
        }

        return Array(deduped.values)
    }

    /// Parses one transcript. Static and pure so it can be tested directly.
    static func parse(fileAt url: URL) -> [CostRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return parse(contents: data)
    }

    /// Assistant lines average ~31 KB (the bulk of it `message.content`, which
    /// we don't want), and a transcript tree is tens of megabytes, so the two
    /// costs that matter are how many lines we hand to a JSON parser and how
    /// fast that parser is.
    ///
    /// Both are addressed here: a raw-byte scan skips any line without a
    /// `"usage"` marker without ever building a `String`, and the survivors go
    /// through `JSONSerialization` rather than `JSONDecoder` — `Codable`'s
    /// reflection is a large fraction of decode time on objects this size, and
    /// we want six scalars out of a deeply nested document.
    static func parse(contents data: Data) -> [CostRecord] {
        var records: [CostRecord] = []
        let marker = Array("\"usage\"".utf8)
        let newline = UInt8(ascii: "\n")

        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            var lineStart = 0
            var index = 0

            while index <= count {
                guard index == count || bytes[index] == newline else {
                    index += 1
                    continue
                }
                let length = index - lineStart
                if length > 0, contains(bytes, from: lineStart, to: index, pattern: marker) {
                    let line = Data(bytes: base.advanced(by: lineStart), count: length)
                    if let record = record(fromLine: line) { records.append(record) }
                }
                lineStart = index + 1
                index += 1
            }
        }
        return records
    }

    /// Byte-range substring search over integer offsets. `Data.SubSequence`'s
    /// `Collection` indices are much slower than this for the volume involved.
    private static func contains(
        _ bytes: UnsafeBufferPointer<UInt8>,
        from start: Int,
        to end: Int,
        pattern: [UInt8]
    ) -> Bool {
        let limit = end - pattern.count
        guard limit >= start else { return false }
        var offset = start
        while offset <= limit {
            var matched = true
            for patternIndex in 0..<pattern.count where bytes[offset + patternIndex] != pattern[patternIndex] {
                matched = false
                break
            }
            if matched { return true }
            offset += 1
        }
        return false
    }

    /// One log line → one record, or `nil` for any line we can't use. These
    /// files carry a dozen record types and change without notice, so every
    /// field is treated as optional and a line we don't understand is skipped
    /// rather than allowed to throw.
    private static func record(fromLine line: Data) -> CostRecord? {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              root["type"] as? String == "assistant",
              let message = root["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let model = message["model"] as? String,
              // An empty model name can't be priced or named, and would surface
              // in the UI as "1 request unpriced ()". A line that doesn't say
              // which model ran is a line we can't use.
              !model.isEmpty,
              model != syntheticModel,
              let timestamp = (root["timestamp"] as? String).flatMap(FlexibleISO8601.date(from:))
        else { return nil }

        // Falls back to the timestamp when ids are missing, which keeps a
        // malformed line from colliding with — and overwriting — a good one.
        let identity = [message["id"] as? String, root["requestId"] as? String]
            .compactMap { $0 }
            .joined(separator: "|")

        return CostRecord(
            identity: identity.isEmpty ? "\(model)|\(timestamp.timeIntervalSince1970)" : identity,
            timestamp: timestamp,
            model: model,
            tokens: tokens(from: usage),
            project: root["cwd"] as? String
        )
    }

    /// Splits cache-creation tokens by TTL. When the nested `cache_creation`
    /// object is absent (older transcripts), the flat total is charged at the
    /// 5-minute rate — the cheaper and far more common of the two, so an
    /// unknown breakdown errs toward under- rather than over-stating cost.
    static func tokens(from usage: [String: Any]) -> TokenCounts {
        let nested = usage["cache_creation"] as? [String: Any]
        let write1h = nested?["ephemeral_1h_input_tokens"] as? Int
        let write5m = nested?["ephemeral_5m_input_tokens"] as? Int

        return TokenCounts(
            input: usage["input_tokens"] as? Int ?? 0,
            output: usage["output_tokens"] as? Int ?? 0,
            cacheWrite5m: (write1h == nil && write5m == nil)
                ? (usage["cache_creation_input_tokens"] as? Int ?? 0)
                : (write5m ?? 0),
            cacheWrite1h: write1h ?? 0,
            cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0
        )
    }

    // MARK: - Summarizing

    /// Pure: records in, summary out. No I/O, so every branch below is directly
    /// unit-testable with synthetic records. Duplicate identities are collapsed
    /// here, so this is safe to call with raw parse output.
    static func summarize(
        records: [CostRecord],
        now: Date,
        pricing: ModelPricing,
        calendar: Calendar
    ) -> CostSummary {
        var summary = CostSummary()
        summary.observedAt = now

        let today = calendar.startOfDay(for: now)
        guard let windowStart = calendar.date(byAdding: .day, value: -29, to: today) else {
            return summary
        }

        var perDay: [Date: (cost: Double, tokens: Int)] = [:]
        var perModel: [String: Double] = [:]
        var perProject: [String: (cost: Double, requests: Int)] = [:]
        var unpriced: Set<String> = []

        // Deduped here as well as in the file scan. It costs nothing, and it
        // makes this function correct on its own terms rather than only when
        // its caller happens to have deduped first — the difference between a
        // right answer and a doubled one.
        var seen: Set<String> = []

        for record in records {
            guard seen.insert(record.identity).inserted else { continue }
            let day = calendar.startOfDay(for: record.timestamp)
            guard day >= windowStart else { continue }

            guard let rate = pricing.rate(for: record.model, at: record.timestamp) else {
                // Counted, named, and kept out of every dollar figure.
                unpriced.insert(record.model)
                summary.unpricedRequests += 1
                continue
            }

            let cost = rate.cost(for: record.tokens)
            summary.requestCount += 1
            summary.last30Days += cost
            summary.last30DaysTokens += record.tokens
            perModel[record.model, default: 0] += cost

            // Priced with this record's own rate, so a mixed-model window is
            // still exact rather than averaged.
            let economics = rate.cacheEconomics(for: record.tokens)
            summary.cache.savedByReads += economics.savedByReads
            summary.cache.premiumOnWrites += economics.premiumOnWrites
            summary.cache.readTokens += economics.readTokens
            summary.cache.writeTokens5m += economics.writeTokens5m
            summary.cache.writeTokens1h += economics.writeTokens1h

            if let project = record.project {
                var bucket = perProject[project] ?? (0, 0)
                bucket.cost += cost
                bucket.requests += 1
                perProject[project] = bucket
            }

            var bucket = perDay[day] ?? (0, 0)
            bucket.cost += cost
            bucket.tokens += record.tokens.total
            perDay[day] = bucket

            if day == today {
                summary.today += cost
                summary.todayTokens += record.tokens
            }
        }

        summary.daily = perDay
            .map { DailyCost(day: $0.key, cost: $0.value.cost, tokens: $0.value.tokens) }
            .sorted { $0.day < $1.day }
        // Ties broken by name so the "top model" line can't flicker between two
        // equal-cost models on consecutive polls.
        if let top = perModel.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) {
            summary.topModel = top.key
            summary.topModelCost = top.value
        }
        summary.byProject = perProject
            .map { ProjectCost(name: $0.key, cost: $0.value.cost, requestCount: $0.value.requests) }
            .sorted { ($0.cost, $1.name) > ($1.cost, $0.name) }
        summary.alternatives = alternatives(for: summary.last30DaysTokens, pricing: pricing, at: now)
        summary.unpricedModels = unpriced.sorted()
        return summary
    }

    /// Reference models the window's tokens are re-priced against.
    ///
    /// A fixed list rather than "everything cheaper than what you used", so the
    /// row doesn't reshuffle between polls as the mix shifts.
    static let referenceModels = ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"]

    /// The same tokens at other models' rates.
    ///
    /// This is arithmetic, not a suggestion. It holds the token counts fixed,
    /// which is precisely the assumption that may not survive contact with
    /// reality — a cheaper model can need more attempts, or produce longer
    /// output, and then it isn't cheaper at all. The UI says so; this function
    /// just does the multiplication.
    static func alternatives(
        for tokens: TokenCounts,
        pricing: ModelPricing,
        at date: Date
    ) -> [ModelAlternative] {
        guard tokens.total > 0 else { return [] }
        return referenceModels.compactMap { model in
            guard let rate = pricing.rate(for: model, at: date) else { return nil }
            return ModelAlternative(model: model, cost: rate.cost(for: tokens))
        }
    }
}
