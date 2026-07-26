import XCTest
@testable import Ullage

final class SnapshotStoreTests: XCTestCase {
    /// Every test gets its own file in a temp directory, so nothing here can
    /// read or damage the real history in Application Support.
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SnapshotStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() throws -> SnapshotStore {
        try SnapshotStore(url: directory.appendingPathComponent("usage.sqlite"))
    }

    private func sample(
        _ kind: UsageSample.Kind = .session,
        at capturedAt: Date,
        percent: Double,
        resetsAt: Date? = nil
    ) -> UsageSample {
        UsageSample(
            provider: .claude,
            kind: kind,
            capturedAt: capturedAt,
            percentUsed: percent,
            resetsAt: resetsAt
        )
    }

    // MARK: - Acceptance: readings survive relaunch

    /// The headline Phase 1 promise. Write, drop the store entirely (as a quit
    /// would), open the same file fresh, and the series is still there.
    func testReadingsSurviveRelaunch() async throws {
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        do {
            let store = try makeStore()
            try await store.record([sample(at: start, percent: 10)])
            try await store.record([sample(at: start.addingTimeInterval(600), percent: 25)])
        }

        let reopened = try makeStore()
        let samples = try await reopened.samples(provider: .claude, kind: .session)
        XCTAssertEqual(samples.map(\.percentUsed), [10, 25])
        XCTAssertEqual(samples.map { SnapshotStore.milliseconds($0.capturedAt) },
                       [start, start.addingTimeInterval(600)].map(SnapshotStore.milliseconds))
    }

    /// `resetsAt` is what tells the forecasting where a window ends, so it has
    /// to survive the millisecond round trip exactly — and a `nil` boundary has
    /// to come back as `nil`, not as 1970.
    func testResetBoundaryRoundTripsIncludingNil() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        let resetsAt = start.addingTimeInterval(5 * 3600)

        try await store.record([sample(at: start, percent: 5, resetsAt: resetsAt)])
        try await store.record([sample(at: start.addingTimeInterval(3600), percent: 40, resetsAt: nil)])

        let samples = try await store.samples(provider: .claude, kind: .session)
        XCTAssertEqual(samples.map(\.percentUsed), [5, 40])
        XCTAssertEqual(
            samples.first?.resetsAt.map { SnapshotStore.milliseconds($0) },
            SnapshotStore.milliseconds(resetsAt)
        )
        XCTAssertNil(samples.last?.resetsAt)
    }

    /// `since:` is how Phase 3 will ask for "the trailing 8 days" without
    /// dragging six months of rows through memory.
    func testSinceFiltersTheSeries() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        for hour in 0..<5 {
            try await store.record([
                sample(at: start.addingTimeInterval(Double(hour) * 3600), percent: Double(hour) * 10)
            ])
        }

        let recent = try await store.samples(
            provider: .claude,
            kind: .session,
            since: start.addingTimeInterval(3 * 3600)
        )
        XCTAssertEqual(recent.map(\.percentUsed), [30, 40])
    }

    func testSeriesAreIsolatedByProviderAndKind() async throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        try await store.record([
            sample(.session, at: now, percent: 10),
            sample(.weekly, at: now, percent: 60),
            UsageSample(provider: .cursor, kind: .total, capturedAt: now, percentUsed: 33, resetsAt: nil)
        ])

        let session = try await store.samples(provider: .claude, kind: .session)
        let weekly = try await store.samples(provider: .claude, kind: .weekly)
        let cursor = try await store.samples(provider: .cursor, kind: .total)
        XCTAssertEqual(session.map(\.percentUsed), [10])
        XCTAssertEqual(weekly.map(\.percentUsed), [60])
        XCTAssertEqual(cursor.map(\.percentUsed), [33])
    }

    // MARK: - Coalescing

    /// A changed percentage is always worth a row, however soon it arrives.
    func testMovementIsAlwaysStored() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        for minute in 0..<6 {
            let inserted = try await store.record([
                sample(at: start.addingTimeInterval(Double(minute) * 300), percent: Double(minute))
            ])
            XCTAssertEqual(inserted, 1)
        }
        let samples = try await store.samples(provider: .claude, kind: .session)
        XCTAssertEqual(samples.count, 6)
    }

    /// The heartbeat rule: while the numbers sit still, polls are dropped until
    /// 30 minutes have passed. This is the main lever keeping the file small.
    func testFlatSeriesIsCoalescedToTheHeartbeat() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 1_760_000_000)

        // Six hours of 5-minute polls at an unchanged 42%: 72 polls.
        for poll in 0..<72 {
            try await store.record([
                sample(at: start.addingTimeInterval(Double(poll) * 300), percent: 42)
            ])
        }

        // One opening row, then one every 30 minutes.
        let samples = try await store.samples(provider: .claude, kind: .session)
        XCTAssertEqual(samples.count, 12)
        XCTAssertTrue(samples.allSatisfy { $0.percentUsed == 42 })
    }

    /// A window resetting is a change in `resetsAt` even when the percentage
    /// happens to land on the same value — it must never be coalesced away.
    func testResetBoundaryChangeIsStored() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        let firstReset = start.addingTimeInterval(3600)

        try await store.record([sample(at: start, percent: 0, resetsAt: firstReset)])
        let inserted = try await store.record([
            sample(at: start.addingTimeInterval(300), percent: 0, resetsAt: firstReset.addingTimeInterval(5 * 3600))
        ])
        XCTAssertEqual(inserted, 1)
    }

    /// The provider serves cached readings during a cooldown, and a cached
    /// reading carries its original `observedAt`. Handing the same observation
    /// back must not fabricate a second data point.
    func testRepeatedObservationIsNotStoredTwice() async throws {
        let store = try makeStore()
        let capturedAt = Date(timeIntervalSince1970: 1_760_000_000)
        let first = try await store.record([sample(at: capturedAt, percent: 12)])
        let second = try await store.record([sample(at: capturedAt, percent: 12)])
        let stored = try await store.samples(provider: .claude, kind: .session).count
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 0)
        XCTAssertEqual(stored, 1)
    }

    /// Guards against a clock adjustment (or a badly ordered replay) rewriting
    /// history behind the newest sample.
    func testOlderThanNewestIsRejected() async throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        try await store.record([sample(at: now, percent: 50)])
        let inserted = try await store.record([sample(at: now.addingTimeInterval(-600), percent: 20)])
        XCTAssertEqual(inserted, 0)
    }

    // MARK: - Payload dedupe

    /// The size lever: identical bodies are stored once, no matter how many
    /// samples reference them.
    func testIdenticalPayloadsAreStoredOnce() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        let payload = Data(#"{"five_hour":{"utilization":42.0}}"#.utf8)

        for hour in 0..<24 {
            try await store.record(
                [sample(at: start.addingTimeInterval(Double(hour) * 3600), percent: Double(hour))],
                rawJSON: payload
            )
        }

        let sampleCount = try await store.samples(provider: .claude, kind: .session).count
        let payloadCount = try await store.payloadCount()
        XCTAssertEqual(sampleCount, 24)
        XCTAssertEqual(payloadCount, 1)
    }

    func testPayloadRoundTripsThroughCompression() async throws {
        let store = try makeStore()
        let capturedAt = Date(timeIntervalSince1970: 1_760_000_000)
        // Repetitive enough that zlib definitely engages, so this exercises the
        // compressed path rather than the raw fallback.
        let payload = Data(String(repeating: #"{"utilization":42.0},"#, count: 200).utf8)

        try await store.record([sample(at: capturedAt, percent: 42)], rawJSON: payload)
        let restored = try await store.rawPayload(forSampleAt: capturedAt, provider: .claude, kind: .session)
        XCTAssertEqual(restored, payload)
    }

    /// A coalesced (dropped) poll must not leave a payload row behind.
    func testSuppressedSampleStoresNoPayload() async throws {
        let store = try makeStore()
        let capturedAt = Date(timeIntervalSince1970: 1_760_000_000)
        try await store.record([sample(at: capturedAt, percent: 42)], rawJSON: Data(#"{"a":1}"#.utf8))
        try await store.record(
            [sample(at: capturedAt.addingTimeInterval(300), percent: 42)],
            rawJSON: Data(#"{"b":2}"#.utf8)
        )
        let payloadCount = try await store.payloadCount()
        XCTAssertEqual(payloadCount, 1)
    }

    // MARK: - Pruning and size

    func testPruneDropsSamplesPastRetention() async throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let old = now.addingTimeInterval(-SnapshotStore.retentionInterval - 86_400)

        try await store.record([sample(at: old, percent: 10)], rawJSON: Data(#"{"old":true}"#.utf8))
        try await store.record([sample(at: now, percent: 90)], rawJSON: Data(#"{"new":true}"#.utf8))

        let deleted = try await store.pruneExpired(now: now)
        XCTAssertEqual(deleted, 1)

        let samples = try await store.samples(provider: .claude, kind: .session)
        let payloadCount = try await store.payloadCount()
        XCTAssertEqual(samples.map(\.percentUsed), [90])
        // The orphaned body goes with it — otherwise payloads would grow forever
        // while samples stayed bounded.
        XCTAssertEqual(payloadCount, 1)
    }

    /// Acceptance: DB growth stays small. Simulates 180 days of 5-minute polling
    /// on both providers — realistically bursty rather than uniformly random,
    /// since a flat idle stretch is what the coalescing is designed to absorb.
    func testFullRetentionWindowStaysWellUnderBudget() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let pollsPerDay = 288
        var sessionPercent = 0.0
        var weeklyPercent = 0.0

        for day in 0..<180 {
            for poll in 0..<pollsPerDay {
                let at = start.addingTimeInterval(Double(day * pollsPerDay + poll) * 300)
                // Roughly a third of the day is active; the rest is idle, where
                // the numbers don't move at all.
                let active = poll % 3 == 0 && poll < 96
                if active {
                    sessionPercent = min(100, sessionPercent + 1.5)
                    weeklyPercent = min(100, weeklyPercent + 0.2)
                }
                if poll == 0 { sessionPercent = 0 }  // the 5-hour window turns over

                try await store.record([
                    sample(.session, at: at, percent: sessionPercent),
                    sample(.weekly, at: at, percent: weeklyPercent)
                ], rawJSON: Data(#"{"five_hour":{"utilization":\#(sessionPercent)}}"#.utf8))
            }
        }

        let bytes = await store.fileSizeBytes()
        let rows = try await store.totalSampleCount()
        // Budget is 20 MB; assert well inside it so a regression in the
        // coalescing or dedupe shows up here rather than on a user's disk.
        XCTAssertLessThan(bytes, 20 * 1024 * 1024, "usage.sqlite grew to \(bytes) bytes over \(rows) samples")
    }

    // MARK: - Schema

    func testSchemaVersionIsRecordedAndReopeningIsIdempotent() async throws {
        let url = directory.appendingPathComponent("usage.sqlite")
        let first = try SnapshotStore(url: url)
        let firstVersion = try await first.schemaVersionOnDisk()
        XCTAssertEqual(firstVersion, SnapshotStore.schemaVersion)

        try await first.record([sample(at: Date(timeIntervalSince1970: 1_760_000_000), percent: 7)])

        let second = try SnapshotStore(url: url)
        let secondVersion = try await second.schemaVersionOnDisk()
        let carriedOver = try await second.samples(provider: .claude, kind: .session).count
        XCTAssertEqual(secondVersion, SnapshotStore.schemaVersion)
        XCTAssertEqual(carriedOver, 1)
    }

    func testEmptyRecordIsANoOp() async throws {
        let store = try makeStore()
        let inserted = try await store.record([])
        let total = try await store.totalSampleCount()
        XCTAssertEqual(inserted, 0)
        XCTAssertEqual(total, 0)
    }
}
