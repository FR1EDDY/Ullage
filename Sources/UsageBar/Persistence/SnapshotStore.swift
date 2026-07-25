import Foundation
import SQLite3
import CryptoKit

/// SQLite's marker for "copy this buffer before you return, don't keep my
/// pointer". Swift hands C a pointer to memory it may reclaim the moment the
/// call returns, so every bound string/blob must be copied. The constant isn't
/// exported to Swift (it's a C macro), hence the bit-cast of -1.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One reading of one usage window at one instant — the unit the forecasting in
/// Phase 3 consumes. Deliberately just numbers: a `(capturedAt, percentUsed)`
/// series plus the window's reset boundary is everything burn rate, projection
/// and anomaly detection need, and nothing more.
struct UsageSample: Equatable, Sendable {
    enum Provider: String, Sendable {
        case claude
        case cursor
    }

    /// Which window this reading describes. Kept as a string in the database
    /// rather than an integer so a dump of the table is readable by eye, which
    /// matters more here than the four bytes it costs.
    enum Kind: String, Sendable {
        /// Claude's rolling 5-hour session window.
        case session
        /// Claude's 7-day all-models window.
        case weekly
        /// Cursor's monthly billing cycle.
        case total
    }

    let provider: Provider
    let kind: Kind
    /// When the reading came off the wire (a provider's `observedAt`), never
    /// when we happened to write it down.
    let capturedAt: Date
    /// 0...100, matching every other percentage in the app.
    let percentUsed: Double
    let resetsAt: Date?
}

/// The app's usage history: a small SQLite file at
/// `~/Library/Application Support/UsageBar/usage.sqlite`.
///
/// **Why raw SQLite and not a library.** macOS ships SQLite, so `import SQLite3`
/// costs zero download bytes and zero build time, where GRDB would add ~1.5 MB
/// to a binary we want to keep in the 10–15 MB range. The C API is verbose but
/// it is confined to this one file; nothing else in the app ever sees it.
///
/// **Why the file stays small.** Naively appending the provider's JSON on every
/// poll would put this in the hundreds of megabytes over the 180-day retention
/// window. Three things stop that:
///   1. *Content-addressed payloads* — the raw body is keyed by its SHA-256 in a
///      separate table, so the byte-identical responses you get back all night
///      while idle are stored **once**; each later poll referencing them costs a
///      foreign key, not a document.
///   2. *Compression* — payload bodies are zlib-compressed (Foundation, no
///      dependency); usage JSON shrinks roughly five-fold.
///   3. *Heartbeat coalescing* — see `shouldStore`. A sample is written when the
///      numbers actually move, or every 30 minutes to keep the series anchored.
///      Flat stretches cost two rows an hour instead of twelve.
///
/// **Why an actor.** The database handle is mutable state touched from the
/// refresh timer and (in tests) from several tasks at once. An `actor` is like a
/// class except the compiler guarantees only one task is inside it at a time, so
/// the writes are serialized without hand-rolled locks — and they happen off the
/// main thread, so a slow disk can never stutter the menu bar.
///
/// All timestamps are stored as **milliseconds since the Unix epoch (UTC)**:
/// exact to compare, half the size of an ISO-8601 string, and it keeps the
/// "all time math in UTC, localize only at display" rule structurally true.
actor SnapshotStore {
    enum StoreError: Error, Equatable {
        case cannotOpen(String)
        case sql(String)
    }

    /// Bumped whenever the tables change; `migrate` reads it from SQLite's
    /// built-in `user_version` slot, which costs no table of our own.
    static let schemaVersion: Int32 = 1

    /// How much history we keep. Long enough for the weekly projections to have
    /// real seasonality to work with, short enough to bound the file.
    static let retentionInterval: TimeInterval = 180 * 24 * 60 * 60

    /// The longest we let a series go without a row while the numbers sit still.
    /// Burn rate is measured first-to-last across a window, so a flat stretch
    /// loses nothing by being represented sparsely — but leaving *no* anchor at
    /// all would make a long idle period indistinguishable from a gap in data.
    static let heartbeatInterval: TimeInterval = 30 * 60

    /// The app-wide store. Optional, and every caller treats it as optional:
    /// usage history is a nice-to-have, and a read-only disk or a corrupt file
    /// must degrade to "no forecasting", never to a menu bar that won't launch.
    static let shared: SnapshotStore? = try? SnapshotStore(url: SnapshotStore.defaultURL())

    static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("UsageBar", isDirectory: true)
            .appendingPathComponent("usage.sqlite", isDirectory: false)
    }

    private let fileURL: URL
    private var db: OpaquePointer?

    /// `url` is injectable so tests run against a temporary file and can never
    /// touch — or be polluted by — the real history on the user's machine.
    init(url: URL) throws {
        self.fileURL = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close_v2(handle)
            throw StoreError.cannotOpen(message)
        }
        self.db = handle
        try Self.migrate(handle)
    }

    deinit {
        sqlite3_close_v2(db)
    }

    // MARK: - Writing

    /// Appends the samples that carry new information, attaching `rawJSON` only
    /// if it isn't already stored. Returns how many rows were actually written,
    /// which is what the size tests assert on.
    ///
    /// The whole thing runs in one transaction: a payload row must never be left
    /// behind without the samples that reference it (or vice versa) if the app
    /// is killed mid-write.
    @discardableResult
    func record(_ samples: [UsageSample], rawJSON: Data? = nil) throws -> Int {
        guard let db, !samples.isEmpty else { return 0 }

        let due = try samples.filter { try Self.shouldStore($0, db: db) }
        guard !due.isEmpty else { return 0 }

        try Self.exec(db, "BEGIN IMMEDIATE;")
        do {
            // Resolved lazily and only once we know a row is going in, so a
            // suppressed heartbeat poll doesn't quietly grow the payload table.
            let payloadID = try rawJSON.map { try Self.payloadID(db, json: $0) }
            for sample in due {
                try Self.insert(db, sample, payloadID: payloadID)
            }
            try Self.exec(db, "COMMIT;")
        } catch {
            try? Self.exec(db, "ROLLBACK;")
            throw error
        }
        return due.count
    }

    /// Drops everything past the retention horizon, then any payload no sample
    /// points at any more, then hands the freed pages back to the filesystem.
    ///
    /// That last step is the one that's easy to forget: a plain `DELETE` leaves
    /// the pages inside the file for SQLite to reuse, so the file never shrinks.
    /// `auto_vacuum = INCREMENTAL` (set at creation) plus this pragma is what
    /// actually returns the space.
    @discardableResult
    func pruneExpired(now: Date = Date()) throws -> Int {
        guard let db else { return 0 }
        let cutoff = Self.milliseconds(now.addingTimeInterval(-Self.retentionInterval))

        let statement = try Self.prepare(db, "DELETE FROM samples WHERE captured_at < ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, cutoff)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
        let deleted = Int(sqlite3_changes(db))

        try Self.exec(db, """
            DELETE FROM payloads
            WHERE id NOT IN (SELECT payload_id FROM samples WHERE payload_id IS NOT NULL);
            """)
        try Self.exec(db, "PRAGMA incremental_vacuum;")
        return deleted
    }

    // MARK: - Reading

    /// One provider/window's history in chronological order — exactly the
    /// `[(Date, Double)]` shape the Phase 3 analytics are specified against.
    func samples(
        provider: UsageSample.Provider,
        kind: UsageSample.Kind,
        since: Date? = nil
    ) throws -> [UsageSample] {
        guard let db else { return [] }
        let sql = """
            SELECT captured_at, percent_used, resets_at FROM samples
            WHERE provider = ? AND kind = ? AND captured_at >= ?
            ORDER BY captured_at ASC;
            """
        let statement = try Self.prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, provider.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, kind.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 3, since.map(Self.milliseconds) ?? Int64.min)

        var results: [UsageSample] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            results.append(UsageSample(
                provider: provider,
                kind: kind,
                capturedAt: Self.date(fromMilliseconds: sqlite3_column_int64(statement, 0)),
                percentUsed: sqlite3_column_double(statement, 1),
                resetsAt: sqlite3_column_type(statement, 2) == SQLITE_NULL
                    ? nil
                    : Self.date(fromMilliseconds: sqlite3_column_int64(statement, 2))
            ))
        }
        return results
    }

    /// The raw response a sample was decoded from, decompressed — the hedge for
    /// "we later want a field we didn't map". Nothing in the app reads this yet.
    func rawPayload(forSampleAt capturedAt: Date, provider: UsageSample.Provider, kind: UsageSample.Kind) throws -> Data? {
        guard let db else { return nil }
        let sql = """
            SELECT p.body, p.compressed FROM samples s
            JOIN payloads p ON p.id = s.payload_id
            WHERE s.provider = ? AND s.kind = ? AND s.captured_at = ?;
            """
        let statement = try Self.prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, provider.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, kind.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 3, Self.milliseconds(capturedAt))

        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(statement, 0)
        else { return nil }
        let count = Int(sqlite3_column_bytes(statement, 0))
        let stored = Data(bytes: bytes, count: count)
        guard sqlite3_column_int(statement, 1) == 1 else { return stored }
        return (try? (stored as NSData).decompressed(using: .zlib)).map(Data.init)
    }

    func totalSampleCount() throws -> Int {
        guard let db else { return 0 }
        return Int(try Self.queryInt64(db, "SELECT COUNT(*) FROM samples;") ?? 0)
    }

    /// How many distinct response bodies are stored. Nothing in the app needs
    /// this, but it's the direct measure of whether content-addressing is doing
    /// its job, so the size tests assert on it.
    func payloadCount() throws -> Int {
        guard let db else { return 0 }
        return Int(try Self.queryInt64(db, "SELECT COUNT(*) FROM payloads;") ?? 0)
    }

    func schemaVersionOnDisk() throws -> Int32 {
        guard let db else { return 0 }
        return Int32(try Self.queryInt64(db, "PRAGMA user_version;") ?? 0)
    }

    /// On-disk size, for the size-budget test and (later) a Settings readout.
    func fileSizeBytes() -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    // MARK: - Coalescing

    private struct StoredSample {
        let capturedAtMs: Int64
        let percentUsed: Double
        let resetsAtMs: Int64?
    }

    /// The heartbeat rule. A sample earns a row when it says something the last
    /// one didn't: the percentage moved, the window reset, or enough time passed
    /// that the series needs a fresh anchor.
    ///
    /// The `capturedAt` guard is load-bearing for a subtler reason: the provider
    /// serves readings from its own cache during cooldowns, and a cached reading
    /// carries the `observedAt` of the fetch it originally came from. Anything
    /// not strictly newer is therefore the *same observation* handed to us
    /// again, not a new one — writing it would fabricate a data point.
    private static func shouldStore(_ sample: UsageSample, db: OpaquePointer) throws -> Bool {
        guard let last = try latest(db, provider: sample.provider, kind: sample.kind) else {
            return true
        }
        let capturedAtMs = milliseconds(sample.capturedAt)
        guard capturedAtMs > last.capturedAtMs else { return false }

        // Compared in the stored millisecond domain, not against the original
        // `Date`s: a round trip truncates sub-millisecond precision, and an
        // unchanged reset boundary must not look "changed" because of it.
        if sample.resetsAt.map(milliseconds) != last.resetsAtMs { return true }
        if abs(sample.percentUsed - last.percentUsed) > 0.0001 { return true }
        return TimeInterval(capturedAtMs - last.capturedAtMs) / 1000 >= heartbeatInterval
    }

    private static func latest(
        _ db: OpaquePointer,
        provider: UsageSample.Provider,
        kind: UsageSample.Kind
    ) throws -> StoredSample? {
        let sql = """
            SELECT captured_at, percent_used, resets_at FROM samples
            WHERE provider = ? AND kind = ?
            ORDER BY captured_at DESC LIMIT 1;
            """
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, provider.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, kind.rawValue, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return StoredSample(
            capturedAtMs: sqlite3_column_int64(statement, 0),
            percentUsed: sqlite3_column_double(statement, 1),
            resetsAtMs: sqlite3_column_type(statement, 2) == SQLITE_NULL
                ? nil
                : sqlite3_column_int64(statement, 2)
        )
    }

    // MARK: - Statements

    private static func insert(_ db: OpaquePointer, _ sample: UsageSample, payloadID: Int64?) throws {
        // `OR IGNORE` against the UNIQUE index is the backstop for the cached
        // reading described in `shouldStore`: even if that check were somehow
        // bypassed, the same observation can only ever occupy one row.
        let sql = """
            INSERT OR IGNORE INTO samples
                (provider, kind, captured_at, percent_used, resets_at, payload_id)
            VALUES (?, ?, ?, ?, ?, ?);
            """
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, sample.provider.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, sample.kind.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 3, milliseconds(sample.capturedAt))
        sqlite3_bind_double(statement, 4, sample.percentUsed)
        if let resetsAt = sample.resetsAt {
            sqlite3_bind_int64(statement, 5, milliseconds(resetsAt))
        } else {
            sqlite3_bind_null(statement, 5)
        }
        if let payloadID {
            sqlite3_bind_int64(statement, 6, payloadID)
        } else {
            sqlite3_bind_null(statement, 6)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Content addressing: the row id for this exact body, inserting it only if
    /// its hash is new. This is the single biggest lever on file size — while
    /// usage is flat the provider returns byte-identical JSON, and all of those
    /// polls collapse onto one stored copy.
    private static func payloadID(_ db: OpaquePointer, json: Data) throws -> Int64 {
        let digest = SHA256.hash(data: json).map { String(format: "%02x", $0) }.joined()
        if let existing = try queryInt64(db, "SELECT id FROM payloads WHERE sha256 = ?;", text: digest) {
            return existing
        }

        // zlib compression of a JSON body effectively never fails, but if it
        // ever did we store the bytes as they are and say so in the row rather
        // than writing something we can't read back.
        let compressed = (try? (json as NSData).compressed(using: .zlib)).map(Data.init)
        let body = compressed ?? json

        let statement = try prepare(
            db,
            "INSERT INTO payloads (sha256, body, compressed, first_seen_at) VALUES (?, ?, ?, ?);"
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, digest, -1, SQLITE_TRANSIENT)
        _ = body.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, 2, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_int(statement, 3, compressed == nil ? 0 : 1)
        sqlite3_bind_int64(statement, 4, milliseconds(Date()))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
        return sqlite3_last_insert_rowid(db)
    }

    // MARK: - Schema

    /// `PRAGMA user_version` is a four-byte integer SQLite keeps in the file
    /// header for exactly this purpose, so versioning the schema costs us no
    /// table of our own. Version 0 is a file we've never touched.
    private static func migrate(_ db: OpaquePointer) throws {
        // Must be set before the first table exists, otherwise SQLite ignores it
        // until a full `VACUUM`. It's what lets `pruneExpired` actually shrink
        // the file instead of just marking pages reusable.
        try exec(db, "PRAGMA auto_vacuum = INCREMENTAL;")

        let version = Int32(try queryInt64(db, "PRAGMA user_version;") ?? 0)
        guard version < schemaVersion else { return }

        if version < 1 {
            try exec(db, """
                CREATE TABLE IF NOT EXISTS payloads (
                    id            INTEGER PRIMARY KEY,
                    sha256        TEXT    NOT NULL UNIQUE,
                    body          BLOB    NOT NULL,
                    compressed    INTEGER NOT NULL DEFAULT 1,
                    first_seen_at INTEGER NOT NULL
                );

                CREATE TABLE IF NOT EXISTS samples (
                    id           INTEGER PRIMARY KEY,
                    provider     TEXT    NOT NULL,
                    kind         TEXT    NOT NULL,
                    captured_at  INTEGER NOT NULL,
                    percent_used REAL    NOT NULL,
                    resets_at    INTEGER,
                    payload_id   INTEGER REFERENCES payloads(id),
                    UNIQUE(provider, kind, captured_at)
                );

                CREATE INDEX IF NOT EXISTS idx_samples_series
                    ON samples (provider, kind, captured_at);
                """)
        }

        try exec(db, "PRAGMA user_version = \(schemaVersion);")
    }

    // MARK: - C API plumbing
    //
    // These are `static` and take the handle explicitly so they stay outside the
    // actor's isolation and can be called from `init`, which runs before the
    // actor is fully formed.

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errorPointer)
            throw StoreError.sql(message)
        }
    }

    /// Compiles one SQL statement. Every caller pairs this with
    /// `defer { sqlite3_finalize(...) }` — an un-finalized statement holds a
    /// read lock on the database until it's collected.
    private static func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }

    private static func queryInt64(_ db: OpaquePointer, _ sql: String, text: String? = nil) throws -> Int64? {
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        if let text {
            sqlite3_bind_text(statement, 1, text, -1, SQLITE_TRANSIENT)
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    // MARK: - Time

    /// Dates cross the SQLite boundary as integer milliseconds since the Unix
    /// epoch. `Date` is already an absolute instant with no time zone attached,
    /// so this is a UTC representation by construction — there is no local time
    /// anywhere below the display layer.
    /// Deliberately *not* overloaded for `Date?`. An optional overload alongside
    /// this one is ambiguous at every call site that passes a non-optional,
    /// because `Date` promotes to `Date?`; callers with an optional map instead.
    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    static func date(fromMilliseconds value: Int64) -> Date {
        Date(timeIntervalSince1970: Double(value) / 1000)
    }
}
