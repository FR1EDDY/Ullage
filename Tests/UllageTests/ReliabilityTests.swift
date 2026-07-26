import XCTest
@testable import Ullage

/// Adversarial conditions, ahead of packaging.
///
/// Everything here is a situation a real machine can be in — a truncated file
/// after a crash, a read-only disk, a log line from a future schema, a clock
/// that jumped. The bar is not "produces the right answer"; it is **does not
/// crash and does not invent a number**. A menu-bar app that dies on launch
/// because one cache file is corrupt is worse than one with no cache at all.
final class ReliabilityTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Reliability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Restore write permission first, or the read-only test leaks a
        // directory the harness can't clean up.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }

    private func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    // MARK: - Corrupt persistence

    /// A half-written SQLite file (power loss, forced quit) must not take the
    /// app down with it. `SnapshotStore.shared` is optional precisely so this
    /// degrades to "no history" rather than "no app".
    func testCorruptDatabaseFailsToOpenWithoutCrashing() async throws {
        let url = file("usage.sqlite")
        try Data("this is definitely not a sqlite database, not even close".utf8).write(to: url)

        // Either it throws, or it opens and behaves. Both are survivable; a
        // crash is not.
        if let store = try? SnapshotStore(url: url) {
            let samples = try? await store.samples(provider: .claude, kind: .session)
            XCTAssertNotNil(samples ?? [])
        }
    }

    /// A truncated database — the more common corruption, since SQLite writes
    /// a valid header early.
    func testTruncatedDatabaseIsSurvivable() async throws {
        let url = file("truncated.sqlite")
        let store = try SnapshotStore(url: url)
        _ = try await store.record([sample(percent: 10)])

        let data = try Data(contentsOf: url)
        try data.prefix(data.count / 3).write(to: url)

        if let reopened = try? SnapshotStore(url: url) {
            _ = try? await reopened.samples(provider: .claude, kind: .session)
            _ = try? await reopened.record([sample(percent: 20)])
        }
    }

    /// A read-only Application Support directory (managed Macs do this) must
    /// not crash the store's initialiser.
    func testReadOnlyDirectoryDoesNotCrash() throws {
        let locked = directory.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        // Expected to throw, and the app treats that as "no history".
        XCTAssertThrowsError(try SnapshotStore(url: locked.appendingPathComponent("usage.sqlite")))
    }

    /// Every shape of broken cost cache rebuilds instead of failing.
    func testCorruptCostCacheRebuilds() async throws {
        let logs = directory.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try assistantLine().write(to: logs.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)

        let cacheURL = file("cost-cache.json")
        for corruption in ["", "{", "null", "[]", "{\"version\":999,\"files\":{}}", String(repeating: "x", count: 5000)] {
            try corruption.write(to: cacheURL, atomically: true, encoding: .utf8)
            let provider = ClaudeCostProvider(
                directory: logs.path, pricing: try pricing(), calendar: .current, cacheURL: cacheURL
            )
            let summary = await provider.summary()
            XCTAssertEqual(summary.requestCount, 1, "failed to rebuild from: \(corruption.prefix(20))")
        }
    }

    /// A cache written where we can't write it back is a non-event.
    func testUnwritableCostCacheStillProducesASummary() async throws {
        let logs = directory.appendingPathComponent("logs2", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try assistantLine().write(to: logs.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)

        let provider = ClaudeCostProvider(
            directory: logs.path,
            pricing: try pricing(),
            calendar: .current,
            // A path that cannot exist.
            cacheURL: URL(fileURLWithPath: "/does/not/exist/anywhere/cache.json")
        )
        let summary = await provider.summary()
        XCTAssertEqual(summary.requestCount, 1)
    }

    /// Missing or broken price table degrades to "unpriced", never to $0 and
    /// never to a crash.
    func testBrokenPriceTableDegradesToUnpriced() throws {
        let url = file("prices.json")
        for corruption in ["", "{}", "not json", "{\"models\":null}", "{\"models\":{\"x\":{}}}"] {
            try corruption.write(to: url, atomically: true, encoding: .utf8)
            let pricing = try? ModelPricing(contentsOf: url)
            // Either it fails to load, or it loads with nothing usable.
            XCTAssertNil(pricing?.rate(for: "claude-opus-4-8", at: Date()))
        }
    }

    /// The compiled-in fallback is the safety net for a missing resource
    /// bundle, which is the realistic Phase 5 packaging failure.
    func testCompiledFallbackCoversTheCommonModelsWithoutAnyFile() {
        for model in ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"] {
            XCTAssertNotNil(ModelPricing.compiledFallback.rate(for: model, at: Date()), model)
        }
    }

    // MARK: - Hostile log input

    /// The transcript format is not ours and changes without notice. Every one
    /// of these must be skipped, not thrown on.
    func testMalformedLogLinesAreAllSurvivable() {
        let hostile = [
            "",
            "\n\n\n",
            "{",
            "}{",
            "null",
            "[]",
            "\"just a string\"",
            "{\"usage\":}",
            "{\"type\":\"assistant\",\"message\":null,\"usage\":1}",
            #"{"type":"assistant","message":{"usage":{"input_tokens":"not a number"},"model":"m"},"timestamp":"2026-07-25T00:00:00Z"}"#,
            #"{"type":"assistant","message":{"usage":{"input_tokens":-5},"model":"m"},"timestamp":"nonsense"}"#,
            #"{"type":"assistant","message":{"usage":{},"model":""},"timestamp":"2026-07-25T00:00:00Z"}"#,
            // A future schema that nests usage somewhere new.
            #"{"type":"assistant","message":{"model":"m","usage":{"input_tokens":{"nested":1}}},"timestamp":"2026-07-25T00:00:00Z"}"#,
            // Enormous numbers.
            #"{"type":"assistant","requestId":"r","message":{"id":"m","model":"claude-opus-4-8","usage":{"input_tokens":999999999999999}},"timestamp":"2026-07-25T00:00:00Z"}"#,
            String(repeating: "a", count: 100_000)
        ].joined(separator: "\n")

        let records = ClaudeCostProvider.parse(contents: Data(hostile.utf8))
        // Whatever survives must be internally consistent — no negatives.
        for record in records {
            XCTAssertGreaterThanOrEqual(record.tokens.input, 0)
            XCTAssertGreaterThanOrEqual(record.tokens.total, 0)
            XCTAssertFalse(record.model.isEmpty)
        }
    }

    /// Invalid UTF-8 in the middle of a transcript must not abort the parse.
    func testInvalidUTF8InTranscriptIsSurvivable() {
        var data = Data(#"{"type":"assistant","requestId":"r","message":{"id":"m","model":"claude-opus-4-8","usage":{"input_tokens":10}},"timestamp":"2026-07-25T00:00:00Z"}"#.utf8)
        data.append(contentsOf: [0x0A, 0xFF, 0xFE, 0xFF, 0x0A])
        data.append(contentsOf: Data(#"{"type":"assistant","requestId":"r2","message":{"id":"m2","model":"claude-opus-4-8","usage":{"input_tokens":20}},"timestamp":"2026-07-25T00:00:00Z"}"#.utf8))

        let records = ClaudeCostProvider.parse(contents: data)
        XCTAssertEqual(records.count, 2, "a bad byte run must not swallow the lines around it")
    }

    /// A missing logs directory is the state of every machine that has never
    /// run Claude Code.
    func testMissingLogDirectoryProducesAnEmptySummary() async throws {
        let provider = ClaudeCostProvider(
            directory: "/nope/not/here",
            pricing: try pricing(),
            calendar: .current,
            cacheURL: file("c.json")
        )
        let summary = await provider.summary()
        XCTAssertTrue(summary.isEmpty)
        XCTAssertEqual(summary.last30Days, 0)
    }

    // MARK: - Hostile API responses

    /// Percentages arrive from an endpoint we do not control.
    func testAbsurdPercentagesAreClamped() {
        for value in [-999.0, 0, 50, 100, 1e9, .infinity, -.infinity, .nan] {
            let claude = ClaudeUsageProvider.normalizedPercent(value)
            let cursor = CursorUsageProvider.normalizedPercent(value)
            for percent in [claude, cursor] {
                XCTAssertFalse(percent.isNaN, "NaN survived the clamp for \(value)")
                XCTAssertGreaterThanOrEqual(percent, 0)
                XCTAssertLessThanOrEqual(percent, 100)
            }
        }
        XCTAssertEqual(ClaudeUsageProvider.normalizedPercent(nil), 0)
        XCTAssertEqual(CursorUsageProvider.normalizedPercent(nil), 0)
    }

    /// Responses that decode but carry nothing usable.
    func testEmptyAndPartialAPIResponsesDecode() throws {
        let bodies = [
            "{}",
            #"{"five_hour":null,"seven_day":null,"limits":null}"#,
            #"{"five_hour":{"utilization":null,"resets_at":null}}"#,
            #"{"limits":[]}"#
        ]
        for body in bodies {
            let decoded = try JSONDecoder().decode(
                ClaudeUsageProvider.UsageResponse.self, from: Data(body.utf8)
            )
            let window = ClaudeUsageProvider.window(from: decoded.fiveHour, isActiveOverride: nil)
            XCTAssertFalse(window.percentUsed.isNaN, body)
            XCTAssertGreaterThanOrEqual(window.percentUsed, 0)
            XCTAssertLessThanOrEqual(window.percentUsed, 100)
        }
    }

    /// A number too large for `Double` makes `JSONDecoder` throw rather than
    /// yield infinity. That's the safe outcome — every decode site in the app
    /// is wrapped, so this surfaces as a decoding failure and the last good
    /// reading stays on screen. Pinned because "it throws" is load-bearing:
    /// were it to start yielding infinity instead, the clamp would be the only
    /// thing standing between it and an `Int(...)` trap.
    func testOversizedNumbersFailToDecodeRatherThanBecomingInfinity() {
        let body = #"{"five_hour":{"utilization":1e400}}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(ClaudeUsageProvider.UsageResponse.self, from: Data(body.utf8))
        )
        // And the clamp holds anyway, if one ever did get through.
        XCTAssertEqual(ClaudeUsageProvider.normalizedPercent(.infinity), 0)
    }

    /// Rate-limit headers are strings from a server; none of these should
    /// produce a reading with a nonsense window.
    func testHostileRateLimitHeaders() {
        let cases: [[String: String]] = [
            ["anthropic-ratelimit-unified-5h-utilization": "not-a-number"],
            ["anthropic-ratelimit-unified-5h-utilization": "NaN"],
            ["anthropic-ratelimit-unified-5h-utilization": "1e400"],
            ["anthropic-ratelimit-unified-5h-utilization": "-50", "anthropic-ratelimit-unified-5h-reset": "abc"],
            ["anthropic-ratelimit-unified-7d-utilization": "", "anthropic-ratelimit-unified-7d-reset": "0"]
        ]
        for headers in cases {
            guard let usage = ClaudeUsageProvider.usage(
                fromRateLimitHeaders: headers, planName: nil, observedAt: Date()
            ) else { continue }
            for window in [usage.session, usage.weeklyAllModels] {
                XCTAssertFalse(window.percentUsed.isNaN, "\(headers)")
                XCTAssertGreaterThanOrEqual(window.percentUsed, 0)
                XCTAssertLessThanOrEqual(window.percentUsed, 100)
            }
        }
    }

    // MARK: - Analytics under nonsense

    /// A fuzz sweep: whatever goes in, nothing NaN, negative, or trapping comes
    /// out. `Int(Double.nan)` is a hard crash in Swift, and these values all
    /// end up inside `Int(...)` conversions on their way to the screen.
    func testAnalyticsNeverProduceNaNOrTrapOnRandomInput() {
        var generator = SystemRandomNumberGenerator()
        let origin = Date(timeIntervalSince1970: 1_784_000_000)

        for _ in 0..<400 {
            let count = Int.random(in: 0...12, using: &generator)
            let points = (0..<count).map { _ -> SeriesPoint in
                SeriesPoint(
                    at: origin.addingTimeInterval(Double.random(in: -900_000...900_000, using: &generator)),
                    percentUsed: Double.random(in: -50...150, using: &generator)
                )
            }
            let resets: Date? = Bool.random(using: &generator)
                ? origin.addingTimeInterval(Double.random(in: -100_000...100_000, using: &generator))
                : nil

            if let forecast = Forecast.session(points: points, resetsAt: resets, now: origin) {
                XCTAssertFalse(forecast.burnRatePerHour.isNaN)
                XCTAssertTrue(forecast.burnRatePerHour.isFinite)
                XCTAssertGreaterThanOrEqual(forecast.burnRatePerHour, 0)
                // Exercises the Int() conversions inside the label.
                XCTAssertFalse(forecast.label.isEmpty)
                XCTAssertFalse(forecast.detail.isEmpty)
            }
            if let projection = WeeklyProjection.cycle(points: points, resetsAt: resets, now: origin) {
                XCTAssertTrue(projection.projectedPercent.isFinite)
                XCTAssertFalse(projection.label.isEmpty)
            }
            if let weekly = WeeklyProjection.weekly(
                sessionPoints: points, weeklyPoints: points, resetsAt: resets, now: origin
            ) {
                XCTAssertTrue(weekly.projectedPercent.isFinite)
                XCTAssertFalse(weekly.label.isEmpty)
                if let unused = weekly.unusedWindows { XCTAssertGreaterThanOrEqual(unused, 0) }
            }
            _ = AnomalyDetector.baseline(points: points, now: origin)
            _ = BurnRate.shortHorizon(points, now: origin)
        }
    }

    /// The specific trap: `Int(Double.nan)` crashes, and a clamp does not
    /// remove NaN.
    func testPercentileRejectsNonFiniteInput() {
        XCTAssertNil(Percentile.p(.nan, of: [1, 2, 3]))
        XCTAssertNil(Percentile.p(0.9, of: [.nan, .nan]))
        XCTAssertNil(Percentile.p(0.9, of: [.infinity]))
        // Finite values among the junk still produce an answer.
        XCTAssertEqual(Percentile.p(0.5, of: [.nan, 4, .infinity, 6]) ?? 0, 5, accuracy: 0.001)
    }

    /// A clock that jumped backwards (NTP correction, manual change) must not
    /// produce a negative rate or a forecast in the past.
    func testBackwardsClockDoesNotProduceNegativeRates() {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let points = [
            SeriesPoint(at: now, percentUsed: 40),
            SeriesPoint(at: now.addingTimeInterval(-3600), percentUsed: 50),
            SeriesPoint(at: now.addingTimeInterval(-7200), percentUsed: 60)
        ]
        if let rate = BurnRate.windowLong(points) {
            XCTAssertGreaterThanOrEqual(rate, 0)
            XCTAssertTrue(rate.isFinite)
        }
        if let forecast = Forecast.session(points: points, resetsAt: now.addingTimeInterval(3600), now: now) {
            XCTAssertGreaterThanOrEqual(forecast.burnRatePerHour, 0)
        }
    }

    // MARK: - Concurrency

    /// The store is written from the refresh task and read by the forecast
    /// engine. Actors serialise that, but "the compiler says so" is worth
    /// confirming under real contention.
    func testConcurrentStoreAccessIsSafe() async throws {
        let store = try SnapshotStore(url: file("concurrent.sqlite"))
        let base = Date()

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    _ = try? await store.record([
                        UsageSample(
                            provider: .claude, kind: .session,
                            capturedAt: base.addingTimeInterval(Double(index) * 120),
                            percentUsed: Double(index), resetsAt: nil
                        )
                    ])
                }
                group.addTask {
                    _ = try? await store.samples(provider: .claude, kind: .session)
                }
                group.addTask { _ = try? await store.pruneExpired() }
            }
        }

        let samples = try await store.samples(provider: .claude, kind: .session)
        XCTAssertFalse(samples.isEmpty)
        // Ordering must hold no matter how the writes interleaved.
        XCTAssertEqual(samples.map(\.capturedAt), samples.map(\.capturedAt).sorted())
    }

    /// Several forecast engines over one store, as a rapid refresh burst would
    /// produce.
    func testConcurrentForecastEnginesDoNotInterfere() async throws {
        let store = try SnapshotStore(url: file("engines.sqlite"))
        let now = Date()
        for step in 0...10 {
            try await store.record([
                UsageSample(provider: .claude, kind: .session,
                            capturedAt: now.addingTimeInterval(Double(step) * 600 - 6000),
                            percentUsed: Double(step) * 8, resetsAt: nil)
            ])
        }

        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    let engine = ForecastEngine(store: store)
                    let forecasts = await engine.forecasts(
                        claudeSessionResetsAt: now.addingTimeInterval(3600),
                        claudeWeeklyResetsAt: nil, cursorResetsAt: nil, now: now
                    )
                    return forecasts.claudeSession != nil
                }
            }
            for await produced in group { XCTAssertTrue(produced) }
        }
    }

    /// Two providers pointed at one cache file, writing at once.
    func testConcurrentCostProvidersShareACacheSafely() async throws {
        let logs = directory.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        for index in 0..<5 {
            try assistantLine(id: "m\(index)", request: "r\(index)")
                .write(to: logs.appendingPathComponent("s\(index).jsonl"), atomically: true, encoding: .utf8)
        }
        let cacheURL = file("shared-cache.json")
        let pricing = try pricing()

        await withTaskGroup(of: Int.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let provider = ClaudeCostProvider(
                        directory: logs.path, pricing: pricing, calendar: .current, cacheURL: cacheURL
                    )
                    return await provider.summary().requestCount
                }
            }
            for await count in group {
                XCTAssertEqual(count, 5, "a shared cache must not lose or duplicate records")
            }
        }
    }

    // MARK: - Helpers

    private func sample(percent: Double, at date: Date = Date()) -> UsageSample {
        UsageSample(provider: .claude, kind: .session, capturedAt: date, percentUsed: percent, resetsAt: nil)
    }

    private func assistantLine(id: String = "msg_1", request: String = "req_1") -> String {
        let iso = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        return #"{"type":"assistant","timestamp":"\#(iso)","requestId":"\#(request)","cwd":"/tmp/proj","message":{"id":"\#(id)","model":"claude-opus-4-8","usage":{"input_tokens":1000,"output_tokens":500}}}"#
    }

    private func pricing() throws -> ModelPricing {
        let url = file("prices-\(UUID().uuidString).json")
        try #"{ "schemaVersion": 1, "models": { "claude-opus-4-8": { "inputPerMTok": 5, "outputPerMTok": 25, "cacheWrite5mPerMTok": 6.25, "cacheWrite1hPerMTok": 10, "cacheReadPerMTok": 0.5 } } }"#
            .write(to: url, atomically: true, encoding: .utf8)
        return try ModelPricing(contentsOf: url)
    }
}
