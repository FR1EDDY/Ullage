import Foundation

/// What one model costs, in US dollars per million tokens.
///
/// Cache writes are split because Anthropic prices the two TTLs differently —
/// a 5-minute cache write is 1.25× the input rate, a 1-hour write is 2×, and a
/// cache *read* is 0.1×. Claude Code uses both TTLs in the same session, so
/// collapsing them into one number would misprice real usage.
struct ModelRate: Equatable, Sendable, Decodable {
    let inputPerMTok: Double
    let outputPerMTok: Double
    let cacheWrite5mPerMTok: Double
    let cacheWrite1hPerMTok: Double
    let cacheReadPerMTok: Double

    /// What caching did to this request's bill.
    ///
    /// Both halves are derived from the rate table rather than from the
    /// published 0.1× / 1.25× / 2× multipliers, so a pricing change flows
    /// through here automatically instead of silently invalidating hardcoded
    /// arithmetic.
    ///   - a cached read would otherwise have been billed as input, so the
    ///     saving is the gap between the two rates;
    ///   - a cache write is billed *above* the input rate, so the premium is
    ///     the gap in the other direction.
    func cacheEconomics(for tokens: TokenCounts) -> CacheEconomics {
        let millions = 1_000_000.0
        let saved = Double(tokens.cacheRead) / millions * (inputPerMTok - cacheReadPerMTok)
        let premium = Double(tokens.cacheWrite5m) / millions * (cacheWrite5mPerMTok - inputPerMTok)
            + Double(tokens.cacheWrite1h) / millions * (cacheWrite1hPerMTok - inputPerMTok)
        return CacheEconomics(
            savedByReads: saved,
            premiumOnWrites: premium,
            readTokens: tokens.cacheRead,
            writeTokens5m: tokens.cacheWrite5m,
            writeTokens1h: tokens.cacheWrite1h
        )
    }

    /// Dollars for one request's token counts. Kept as a pure function of
    /// numbers so the cost math is trivially testable.
    func cost(for tokens: TokenCounts) -> Double {
        let millions = 1_000_000.0
        return Double(tokens.input) / millions * inputPerMTok
            + Double(tokens.output) / millions * outputPerMTok
            + Double(tokens.cacheWrite5m) / millions * cacheWrite5mPerMTok
            + Double(tokens.cacheWrite1h) / millions * cacheWrite1hPerMTok
            + Double(tokens.cacheRead) / millions * cacheReadPerMTok
    }
}

/// The bundled price list, plus any user overrides.
///
/// **Why this doesn't use `Bundle.module`.** SwiftPM synthesizes that accessor
/// with a `fatalError` when the resource bundle can't be located — so an app
/// packaged by hand (Phase 5 builds the `.app` with a shell script, not Xcode)
/// would *crash on launch* rather than degrade. Instead we search a list of
/// plausible locations and fall through to a small compiled-in table. The worst
/// case is some models showing as "unpriced"; it is never a crash.
///
/// Lookup order, first hit wins per model:
///   1. `~/Library/Application Support/Ullage/model_prices.json` — the user's
///      own overrides, so a price correction never needs an app update.
///   2. The bundled `model_prices.json`.
///   3. `fallbackRates` below.
struct ModelPricing: Sendable {
    /// Parsed shape of `model_prices.json`.
    private struct PriceFile: Decodable {
        struct Entry: Decodable {
            let inputPerMTok: Double
            let outputPerMTok: Double
            let cacheWrite5mPerMTok: Double
            let cacheWrite1hPerMTok: Double
            let cacheReadPerMTok: Double
            /// Introductory pricing, and the last day it applies (inclusive,
            /// UTC). Claude Sonnet 5 is discounted through 2026-08-31; ignoring
            /// that would overstate its cost by 50% for anyone using it today.
            let promotionalUntil: String?
            let promotional: ModelRate?

            var standardRate: ModelRate {
                ModelRate(
                    inputPerMTok: inputPerMTok,
                    outputPerMTok: outputPerMTok,
                    cacheWrite5mPerMTok: cacheWrite5mPerMTok,
                    cacheWrite1hPerMTok: cacheWrite1hPerMTok,
                    cacheReadPerMTok: cacheReadPerMTok
                )
            }
        }
        let models: [String: Entry]
    }

    private let entries: [String: PriceFile.Entry]

    /// Loaded once. Pricing changes far more slowly than the app polls, and a
    /// re-read per poll would be pure I/O for nothing.
    static let shared = ModelPricing()

    init() {
        var merged = Self.loadEntries(at: Self.bundledURL()) ?? Self.fallbackEntries
        // User overrides are merged per-model rather than replacing the whole
        // table, so someone correcting one price doesn't silently lose every
        // other model.
        if let overrides = Self.loadEntries(at: Self.overrideURL()) {
            merged.merge(overrides) { _, override in override }
        }
        self.entries = merged
    }

    /// Test seam: build a table from an explicit file, with no user overrides.
    init(contentsOf url: URL) throws {
        guard let entries = Self.loadEntries(at: url) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.entries = entries
    }

    private init(entries: [String: PriceFile.Entry]) {
        self.entries = entries
    }

    /// The rate for a model id as it appears in Claude Code's logs, or `nil` if
    /// we have no price for it — which the UI must surface as "unpriced" rather
    /// than silently charging $0.
    ///
    /// `at` picks between standard and introductory pricing; it's the time of
    /// the *request*, not now, so history stays priced as it was billed.
    func rate(for model: String, at date: Date) -> ModelRate? {
        guard let entry = entry(for: model) else { return nil }
        if let promotional = entry.promotional,
           let until = entry.promotionalUntil.flatMap(Self.endOfDayUTC(_:)),
           date <= until {
            return promotional
        }
        return entry.standardRate
    }

    func knowsModel(_ model: String) -> Bool {
        entry(for: model) != nil
    }

    /// Exact match first, then again with a trailing `-YYYYMMDD` snapshot suffix
    /// removed: the logs carry both bare aliases (`claude-opus-4-8`) and dated
    /// ids (`claude-haiku-4-5-20251001`) for what is one priced model.
    private func entry(for model: String) -> PriceFile.Entry? {
        if let exact = entries[model] { return exact }
        guard let undated = Self.strippingDateSuffix(model) else { return nil }
        return entries[undated]
    }

    static func strippingDateSuffix(_ model: String) -> String? {
        guard let separator = model.lastIndex(of: "-") else { return nil }
        let suffix = model[model.index(after: separator)...]
        guard suffix.count == 8, suffix.allSatisfy(\.isNumber) else { return nil }
        return String(model[..<separator])
    }

    /// Promotional windows are stated as a calendar date and run to the end of
    /// it. Parsed in UTC, like every other date in this app.
    private static func endOfDayUTC(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: value).map { $0.addingTimeInterval(86_400 - 1) }
    }

    // MARK: - Locating the table

    static func overrideURL() -> URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        .appendingPathComponent("Ullage", isDirectory: true)
        .appendingPathComponent("model_prices.json", isDirectory: false)
    }

    /// Every place the bundled table might plausibly live, across `swift run`,
    /// `swift test`, and a hand-assembled `.app`. Checked in order; the first
    /// file that parses wins.
    private static func bundledURL() -> URL? {
        let name = "model_prices"
        var candidates: [URL] = []

        for bundle in [Bundle.main] + Bundle.allBundles {
            if let direct = bundle.url(forResource: name, withExtension: "json") {
                candidates.append(direct)
            }
            // SwiftPM emits `Ullage_Ullage.bundle` beside the built
            // executable; a packaged .app copies the json into Resources/.
            // The SwiftPM bundle is flat on a command-line build and wrapped in
            // `Contents/Resources` when it's a real bundle, so try both.
            for root in [bundle.resourceURL, bundle.bundleURL, bundle.bundleURL.deletingLastPathComponent()].compactMap({ $0 }) {
                candidates.append(root.appendingPathComponent("\(name).json"))
                let spm = root.appendingPathComponent("Ullage_Ullage.bundle", isDirectory: true)
                candidates.append(spm.appendingPathComponent("\(name).json"))
                candidates.append(spm.appendingPathComponent("Contents/Resources/\(name).json"))
            }
        }

        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func loadEntries(at url: URL?) -> [String: PriceFile.Entry]? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        guard let decoded = try? JSONDecoder().decode(PriceFile.self, from: data) else { return nil }
        return decoded.models
    }

    // MARK: - Compiled-in fallback

    /// A last resort covering the models in current use, so a missing resource
    /// bundle degrades to "most things priced" rather than "nothing priced".
    /// Deliberately small — `ModelPricingTests` asserts every entry here agrees
    /// with the bundled JSON, so the two can't drift apart unnoticed.
    private static let fallbackEntries: [String: PriceFile.Entry] = [
        "claude-fable-5": .init(inputPerMTok: 10, outputPerMTok: 50, cacheWrite5mPerMTok: 12.5, cacheWrite1hPerMTok: 20, cacheReadPerMTok: 1, promotionalUntil: nil, promotional: nil),
        "claude-opus-5": .init(inputPerMTok: 5, outputPerMTok: 25, cacheWrite5mPerMTok: 6.25, cacheWrite1hPerMTok: 10, cacheReadPerMTok: 0.5, promotionalUntil: nil, promotional: nil),
        "claude-opus-4-8": .init(inputPerMTok: 5, outputPerMTok: 25, cacheWrite5mPerMTok: 6.25, cacheWrite1hPerMTok: 10, cacheReadPerMTok: 0.5, promotionalUntil: nil, promotional: nil),
        // Carries Sonnet 5's introductory pricing too — without it, a missing
        // resource bundle would silently overstate every Sonnet 5 request by
        // 50% until the promotional window closes.
        "claude-sonnet-5": .init(
            inputPerMTok: 3, outputPerMTok: 15, cacheWrite5mPerMTok: 3.75, cacheWrite1hPerMTok: 6, cacheReadPerMTok: 0.3,
            promotionalUntil: "2026-08-31",
            promotional: ModelRate(inputPerMTok: 2, outputPerMTok: 10, cacheWrite5mPerMTok: 2.5, cacheWrite1hPerMTok: 4, cacheReadPerMTok: 0.2)
        ),
        "claude-sonnet-4-6": .init(inputPerMTok: 3, outputPerMTok: 15, cacheWrite5mPerMTok: 3.75, cacheWrite1hPerMTok: 6, cacheReadPerMTok: 0.3, promotionalUntil: nil, promotional: nil),
        "claude-haiku-4-5": .init(inputPerMTok: 1, outputPerMTok: 5, cacheWrite5mPerMTok: 1.25, cacheWrite1hPerMTok: 2, cacheReadPerMTok: 0.1, promotionalUntil: nil, promotional: nil)
    ]

    /// The compiled-in table as a lookup, so the drift test exercises the same
    /// resolution path (dated ids, promotional windows) as the real one.
    static let compiledFallback = ModelPricing(entries: fallbackEntries)

    static var fallbackModelIDs: [String] { fallbackEntries.keys.sorted() }
}
