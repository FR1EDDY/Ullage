import XCTest
@testable import UsageBar

final class ClaudeCostProviderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CostProviderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    /// The exact assistant-line shape observed live on 2026-07-25.
    private func assistantLine(
        model: String = "claude-opus-4-8",
        messageID: String = "msg_1",
        requestID: String = "req_1",
        timestamp: String = "2026-07-23T22:48:58.627Z",
        input: Int = 2,
        output: Int = 338,
        cacheCreation: Int? = 9812,
        ephemeral1h: Int? = 9812,
        ephemeral5m: Int? = 0,
        cacheRead: Int = 12611
    ) -> String {
        var usage: [String: Any] = [
            "input_tokens": input,
            "output_tokens": output,
            "cache_read_input_tokens": cacheRead
        ]
        if let cacheCreation { usage["cache_creation_input_tokens"] = cacheCreation }
        if ephemeral1h != nil || ephemeral5m != nil {
            var nested: [String: Any] = [:]
            if let ephemeral1h { nested["ephemeral_1h_input_tokens"] = ephemeral1h }
            if let ephemeral5m { nested["ephemeral_5m_input_tokens"] = ephemeral5m }
            usage["cache_creation"] = nested
        }
        let object: [String: Any] = [
            "type": "assistant",
            "timestamp": timestamp,
            "requestId": requestID,
            "message": ["id": messageID, "model": model, "role": "assistant", "usage": usage]
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func write(_ lines: [String], named name: String = "session.jsonl") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func pricing() throws -> ModelPricing {
        let url = directory.appendingPathComponent("prices.json")
        let json = """
        { "schemaVersion": 1, "models": {
            "claude-opus-4-8": { "inputPerMTok": 5, "outputPerMTok": 25, "cacheWrite5mPerMTok": 6.25, "cacheWrite1hPerMTok": 10, "cacheReadPerMTok": 0.5 },
            "claude-haiku-4-5": { "inputPerMTok": 1, "outputPerMTok": 5, "cacheWrite5mPerMTok": 1.25, "cacheWrite1hPerMTok": 2, "cacheReadPerMTok": 0.1 }
        } }
        """
        try json.write(to: url, atomically: true, encoding: .utf8)
        return try ModelPricing(contentsOf: url)
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func isoDate(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: value)!
    }

    // MARK: - Parsing

    func testParsesTheLiveAssistantShape() throws {
        let url = try write([assistantLine()])
        let records = ClaudeCostProvider.parse(fileAt: url)

        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.model, "claude-opus-4-8")
        XCTAssertEqual(record.tokens.input, 2)
        XCTAssertEqual(record.tokens.output, 338)
        XCTAssertEqual(record.tokens.cacheRead, 12611)
        // The nested split is what makes cache pricing correct.
        XCTAssertEqual(record.tokens.cacheWrite1h, 9812)
        XCTAssertEqual(record.tokens.cacheWrite5m, 0)
    }

    /// The single most consequential detail in this file: Claude Code writes
    /// the same request more than once, so counting lines instead of distinct
    /// requests roughly doubles every figure.
    func testRepeatedRecordsForOneRequestAreCountedOnce() throws {
        let line = assistantLine()
        let url = try write([line, line, line])
        let records = ClaudeCostProvider.parse(fileAt: url)
        XCTAssertEqual(records.count, 3, "parse keeps duplicates; dedupe happens on identity")
        XCTAssertEqual(Set(records.map(\.identity)).count, 1)

        let summary = ClaudeCostProvider.summarize(
            records: records,
            now: isoDate("2026-07-23T23:00:00Z"),
            pricing: try pricing(),
            calendar: utcCalendar
        )
        XCTAssertEqual(summary.requestCount, 1)
    }

    /// A missing `cache_creation` object (older transcripts) must still price
    /// the write — at the cheaper 5-minute rate, so an unknown split can't
    /// overstate cost.
    func testFlatCacheCreationFallsBackToTheFiveMinuteBucket() throws {
        let url = try write([assistantLine(cacheCreation: 4_000, ephemeral1h: nil, ephemeral5m: nil)])
        let record = try XCTUnwrap(ClaudeCostProvider.parse(fileAt: url).first)
        XCTAssertEqual(record.tokens.cacheWrite5m, 4_000)
        XCTAssertEqual(record.tokens.cacheWrite1h, 0)
    }

    /// `<synthetic>` marks locally-generated messages that never hit the API —
    /// excluded entirely rather than counted as an unpriced model.
    func testSyntheticModelIsExcluded() throws {
        let url = try write([assistantLine(model: "<synthetic>", messageID: "msg_s")])
        XCTAssertTrue(ClaudeCostProvider.parse(fileAt: url).isEmpty)
    }

    /// These files carry a dozen record types and change without notice; a line
    /// we don't understand must be skipped, never throw.
    func testNonAssistantAndMalformedLinesAreSkipped() throws {
        let url = try write([
            #"{"type":"user","message":{"role":"user","content":"hi"}}"#,
            #"{"type":"summary","summary":"...","usage":"not an object"}"#,
            "",
            "{ this is not json at all, but mentions \"usage\" }",
            #"{"type":"assistant","message":{"model":"claude-opus-4-8","usage":{"input_tokens":5}}}"#, // no timestamp
            assistantLine()
        ])
        let records = ClaudeCostProvider.parse(fileAt: url)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.tokens.output, 338)
    }

    // MARK: - Summarizing

    func testTodayAndThirtyDayTotalsAndTopModel() throws {
        let now = isoDate("2026-07-25T18:00:00Z")
        let records = [
            // Today: 1M input on Opus = $5.00
            CostRecord(identity: "a", timestamp: isoDate("2026-07-25T09:00:00Z"), model: "claude-opus-4-8",
                       tokens: TokenCounts(input: 1_000_000)),
            // 10 days ago: 1M output on Opus = $25.00
            CostRecord(identity: "b", timestamp: isoDate("2026-07-15T09:00:00Z"), model: "claude-opus-4-8",
                       tokens: TokenCounts(output: 1_000_000)),
            // 10 days ago on Haiku: 1M output = $5.00
            CostRecord(identity: "c", timestamp: isoDate("2026-07-15T10:00:00Z"), model: "claude-haiku-4-5",
                       tokens: TokenCounts(output: 1_000_000)),
            // Outside the 30-day window entirely.
            CostRecord(identity: "d", timestamp: isoDate("2026-05-01T09:00:00Z"), model: "claude-opus-4-8",
                       tokens: TokenCounts(output: 1_000_000))
        ]

        let summary = ClaudeCostProvider.summarize(records: records, now: now, pricing: try pricing(), calendar: utcCalendar)

        XCTAssertEqual(summary.today, 5.00, accuracy: 0.0001)
        XCTAssertEqual(summary.last30Days, 35.00, accuracy: 0.0001)
        XCTAssertEqual(summary.requestCount, 3)
        XCTAssertEqual(summary.topModel, "claude-opus-4-8")
        XCTAssertEqual(summary.topModelCost, 30.00, accuracy: 0.0001)
        XCTAssertEqual(summary.daily.count, 2)
        XCTAssertEqual(summary.daily.map(\.day), summary.daily.map(\.day).sorted())
        XCTAssertEqual(summary.last30DaysTokens.total, 3_000_000)
        XCTAssertEqual(summary.todayTokens.total, 1_000_000)
    }

    /// Acceptance: unknown models degrade gracefully — named and counted, but
    /// never folded into a dollar figure as $0.
    func testUnpricedModelsAreReportedNotZeroed() throws {
        let now = isoDate("2026-07-25T18:00:00Z")
        let records = [
            CostRecord(identity: "a", timestamp: isoDate("2026-07-25T09:00:00Z"), model: "claude-opus-4-8",
                       tokens: TokenCounts(input: 1_000_000)),
            CostRecord(identity: "b", timestamp: isoDate("2026-07-25T10:00:00Z"), model: "claude-future-9",
                       tokens: TokenCounts(input: 5_000_000)),
            CostRecord(identity: "c", timestamp: isoDate("2026-07-25T11:00:00Z"), model: "claude-future-9",
                       tokens: TokenCounts(input: 5_000_000))
        ]

        let summary = ClaudeCostProvider.summarize(records: records, now: now, pricing: try pricing(), calendar: utcCalendar)

        XCTAssertEqual(summary.today, 5.00, accuracy: 0.0001, "unpriced usage must not inflate or deflate the total")
        XCTAssertEqual(summary.requestCount, 1)
        XCTAssertEqual(summary.unpricedModels, ["claude-future-9"])
        XCTAssertEqual(summary.unpricedRequests, 2)
        // Their tokens stay out of the totals too — a token count next to a
        // dollar figure that excludes them would misrepresent the rate.
        XCTAssertEqual(summary.last30DaysTokens.total, 1_000_000)
        XCTAssertFalse(summary.isEmpty)
    }

    func testEmptyInputProducesAnEmptySummary() throws {
        let summary = ClaudeCostProvider.summarize(
            records: [],
            now: isoDate("2026-07-25T18:00:00Z"),
            pricing: try pricing(),
            calendar: utcCalendar
        )
        XCTAssertTrue(summary.isEmpty)
        XCTAssertEqual(summary.today, 0)
        XCTAssertNil(summary.topModel)
        XCTAssertTrue(summary.daily.isEmpty)
    }

    // MARK: - End to end

    /// Acceptance: cost and tokens render with no network at all.
    func testScansADirectoryTreeWithoutNetwork() async throws {
        let nested = directory.appendingPathComponent("project-a", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let recent = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        try (assistantLine(messageID: "msg_1", requestID: "req_1", timestamp: recent, input: 1_000_000, output: 0, cacheCreation: nil, ephemeral1h: nil, ephemeral5m: nil, cacheRead: 0))
            .write(to: nested.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)

        let provider = ClaudeCostProvider(
            directory: directory.path,
            pricing: try pricing(),
            calendar: .current,
            cacheURL: directory.appendingPathComponent("cache.json")
        )
        let summary = await provider.summary()

        XCTAssertEqual(summary.requestCount, 1)
        XCTAssertEqual(summary.last30Days, 5.00, accuracy: 0.0001)
    }

    /// The same request appearing in two transcripts — which is what resuming a
    /// session produces — must be counted once.
    func testDeduplicatesAcrossFiles() async throws {
        let recent = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        let line = assistantLine(timestamp: recent, input: 1_000_000, output: 0, cacheCreation: nil, ephemeral1h: nil, ephemeral5m: nil, cacheRead: 0)
        _ = try write([line], named: "first.jsonl")
        _ = try write([line], named: "resumed.jsonl")

        let provider = ClaudeCostProvider(
            directory: directory.path,
            pricing: try pricing(),
            calendar: .current,
            cacheURL: directory.appendingPathComponent("cache.json")
        )
        let summary = await provider.summary()
        XCTAssertEqual(summary.requestCount, 1)
        XCTAssertEqual(summary.last30Days, 5.00, accuracy: 0.0001)
    }

    /// The parse cache is what makes relaunch instant instead of a multi-second
    /// re-read, so it has to survive the process that wrote it.
    func testParseCacheSurvivesRelaunchAndProducesTheSameNumbers() async throws {
        let recent = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        _ = try write([assistantLine(timestamp: recent, input: 1_000_000, output: 0, cacheCreation: nil, ephemeral1h: nil, ephemeral5m: nil, cacheRead: 0)])
        let cacheURL = directory.appendingPathComponent("cache.json")

        let first = ClaudeCostProvider(directory: directory.path, pricing: try pricing(), calendar: .current, cacheURL: cacheURL)
        let before = await first.summary()
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path), "cache was not written")

        // A brand-new provider, as a relaunch would create.
        let second = ClaudeCostProvider(directory: directory.path, pricing: try pricing(), calendar: .current, cacheURL: cacheURL)
        let after = await second.summary()

        // `observedAt` is when the summary was computed and is *expected* to
        // differ between the two runs; everything derived from the transcripts
        // must be identical.
        XCTAssertEqual(before.today, after.today)
        XCTAssertEqual(before.last30Days, after.last30Days)
        XCTAssertEqual(before.requestCount, after.requestCount)
        XCTAssertEqual(before.last30DaysTokens, after.last30DaysTokens)
        XCTAssertEqual(before.topModel, after.topModel)
        XCTAssertEqual(before.daily, after.daily)
        XCTAssertNotEqual(before.observedAt, after.observedAt)
    }

    /// An edited transcript must be re-read — a cache keyed on size and mtime
    /// that ignored a change would freeze the numbers.
    func testEditedFileIsReparsed() async throws {
        let recent = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        let url = try write([assistantLine(timestamp: recent, input: 1_000_000, output: 0, cacheCreation: nil, ephemeral1h: nil, ephemeral5m: nil, cacheRead: 0)])
        let cacheURL = directory.appendingPathComponent("cache.json")
        let provider = ClaudeCostProvider(directory: directory.path, pricing: try pricing(), calendar: .current, cacheURL: cacheURL)

        let before = await provider.summary()
        XCTAssertEqual(before.requestCount, 1)

        let appended = assistantLine(messageID: "msg_2", requestID: "req_2", timestamp: recent, input: 1_000_000, output: 0, cacheCreation: nil, ephemeral1h: nil, ephemeral5m: nil, cacheRead: 0)
        try ([
            assistantLine(timestamp: recent, input: 1_000_000, output: 0, cacheCreation: nil, ephemeral1h: nil, ephemeral5m: nil, cacheRead: 0),
            appended
        ].joined(separator: "\n")).write(to: url, atomically: true, encoding: .utf8)

        let after = await provider.summary()
        XCTAssertEqual(after.requestCount, 2)
        XCTAssertEqual(after.last30Days, 10.00, accuracy: 0.0001)
    }

    /// Transcripts older than the window are never opened — the check that
    /// keeps this bounded as the log directory grows without limit.
    func testFilesOutsideTheWindowAreIgnored() async throws {
        let url = try write([assistantLine(timestamp: "2020-01-01T00:00:00Z", input: 1_000_000)])
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
            ofItemAtPath: url.path
        )

        let provider = ClaudeCostProvider(
            directory: directory.path,
            pricing: try pricing(),
            calendar: .current,
            cacheURL: directory.appendingPathComponent("cache.json")
        )
        let summary = await provider.summary()
        XCTAssertTrue(summary.isEmpty)
    }

    func testMissingDirectoryIsNotAnError() async throws {
        let provider = ClaudeCostProvider(
            directory: directory.appendingPathComponent("does-not-exist").path,
            pricing: try pricing(),
            calendar: .current,
            cacheURL: directory.appendingPathComponent("cache.json")
        )
        let summary = await provider.summary()
        XCTAssertTrue(summary.isEmpty)
    }
}
