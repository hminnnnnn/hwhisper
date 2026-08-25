import Foundation
import SQLite3

/// `sqlite3_bind_text` needs SQLITE_TRANSIENT (make a private copy) because
/// Swift string UTF-8 buffers don't outlive the call; the C macro doesn't
/// import, so rebuild it.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite-backed `HistoryStore`.
///
/// Search is a plain `LIKE '%query%'` table scan rather than FTS5 (a
/// leading `%` can never use an index — the created_at index only supplies
/// the result ordering): the
/// system FTS5 tokenizer (unicode61) splits on whitespace and only matches
/// token *prefixes*, which makes Korean substring queries ("어제 회의" inside
/// a longer compound) silently miss — LIKE is substring-correct for Korean
/// and fast enough at personal-history scale (thousands of rows).
///
/// An actor so the single `OpaquePointer` connection is confined to one
/// isolation domain; SQLite serialized mode is not relied upon.
public actor SQLiteHistoryStore: HistoryStore {
    public enum StoreError: Error {
        case openFailed(String)
        case queryFailed(String)
    }

    /// Owns the sqlite handle so closing happens in a plain class deinit —
    /// an actor's (nonisolated) deinit can't legally touch the non-Sendable
    /// `OpaquePointer` under Swift 6 strict concurrency. `@unchecked
    /// Sendable` is sound because the actor is the only holder and all use
    /// stays inside its isolation.
    private final class Connection: @unchecked Sendable {
        let handle: OpaquePointer
        init(handle: OpaquePointer) { self.handle = handle }
        deinit { sqlite3_close_v2(handle) }
    }

    private let databaseURL: URL
    private var db: Connection?

    /// `databaseURL`'s parent directory is created (0700) if missing and the
    /// database file is chmodded 0600 after first open — history contains
    /// everything the user has dictated, so it gets the same owner-only
    /// treatment as `CredentialStore`.
    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    private func connection() throws -> OpaquePointer {
        if let db { return db.handle }

        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 failed"
            if let handle { sqlite3_close_v2(handle) }
            throw StoreError.openFailed(message)
        }

        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)

        let schema = """
        CREATE TABLE IF NOT EXISTS history (
            id TEXT PRIMARY KEY,
            raw_text TEXT NOT NULL,
            refined_text TEXT,
            target_bundle_id TEXT,
            outcome TEXT NOT NULL,
            created_at REAL NOT NULL,
            duration_seconds REAL NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_history_created_at ON history(created_at DESC);
        """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(handle))
            sqlite3_close_v2(handle)
            throw StoreError.openFailed(message)
        }

        // v0.2 migration: databases created before the home-tab stats work
        // lack `duration_seconds`. ALTER TABLE fails harmlessly with
        // "duplicate column name" once the column exists — that's the
        // idempotence check, so the result is deliberately ignored.
        sqlite3_exec(handle, "ALTER TABLE history ADD COLUMN duration_seconds REAL NOT NULL DEFAULT 0", nil, nil, nil)

        // v0.2.16 migration: `word_count` lets the home tab total words in SQL
        // instead of loading every transcript. The default is -1, not 0, so
        // rows predating the column are distinguishable from rows that really
        // contain no words — otherwise the backfill below could not tell them
        // apart and old dictations would silently count as zero words.
        sqlite3_exec(handle, "ALTER TABLE history ADD COLUMN word_count INTEGER NOT NULL DEFAULT -1", nil, nil, nil)

        db = Connection(handle: handle)
        backfillWordCounts(handle)
        return handle
    }

    /// Schema epoch stored in SQLite's `PRAGMA user_version`. ≥1 means the
    /// `word_count` backfill has completed, so opens can skip the "any rows
    /// left to fill?" scan — that scan is a full table scan on an unindexed
    /// predicate, and running it on EVERY launch forever only holds up while
    /// the table stays small. Living in the DB file itself, the marker
    /// travels with backups: restoring an old DB re-triggers the backfill
    /// correctly.
    private static let schemaEpochBackfilled: Int32 = 1

    /// One-time fill of `word_count` for rows written before the column
    /// existed. Gated by `PRAGMA user_version` so it runs exactly once per
    /// database, not once per launch.
    private func backfillWordCounts(_ db: OpaquePointer) {
        var epoch: Int32 = 0
        var pragma: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &pragma, nil) == SQLITE_OK,
           sqlite3_step(pragma) == SQLITE_ROW {
            epoch = sqlite3_column_int(pragma, 0)
        }
        sqlite3_finalize(pragma)
        guard epoch < Self.schemaEpochBackfilled else { return }
        defer {
            sqlite3_exec(db, "PRAGMA user_version = \(Self.schemaEpochBackfilled)", nil, nil, nil)
        }

        var select: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, raw_text, refined_text FROM history WHERE word_count < 0", -1, &select, nil) == SQLITE_OK else { return }
        var pending: [(id: String, words: Int)] = []
        while sqlite3_step(select) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(select, 0), let rawText = sqlite3_column_text(select, 1) else { continue }
            let raw = String(cString: rawText)
            let refined = sqlite3_column_text(select, 2).map { String(cString: $0) }
            pending.append((String(cString: idText), TranscriptMetrics.wordCount(refined ?? raw)))
        }
        sqlite3_finalize(select)
        guard !pending.isEmpty else { return }

        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        var update: OpaquePointer?
        if sqlite3_prepare_v2(db, "UPDATE history SET word_count = ? WHERE id = ?", -1, &update, nil) == SQLITE_OK {
            for row in pending {
                sqlite3_reset(update)
                sqlite3_bind_int(update, 1, Int32(row.words))
                sqlite3_bind_text(update, 2, row.id, -1, sqliteTransient)
                sqlite3_step(update)
            }
        }
        sqlite3_finalize(update)
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    /// `created_at >= ?` when a start date is given, otherwise everything.
    /// Returned as SQL text plus a binder so each query below states its
    /// range once.
    private func rangeClause(_ date: Date?) -> String {
        date == nil ? "" : " WHERE created_at >= ?"
    }

    public func aggregate(since date: Date?) async throws -> HistoryAggregate {
        let db = try connection()
        let sql = "SELECT COUNT(*), COALESCE(SUM(duration_seconds), 0), COALESCE(SUM(MAX(word_count, 0)), 0) FROM history" + rangeClause(date)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        if let date { sqlite3_bind_double(statement, 1, date.timeIntervalSince1970) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return HistoryAggregate() }
        return HistoryAggregate(
            dictations: Int(sqlite3_column_int(statement, 0)),
            speechSeconds: sqlite3_column_double(statement, 1),
            words: Int(sqlite3_column_int64(statement, 2))
        )
    }

    public func appCounts(since date: Date?) async throws -> [HistoryAppCount] {
        let db = try connection()
        let scope = date == nil
            ? " WHERE target_bundle_id IS NOT NULL AND target_bundle_id <> ''"
            : " WHERE created_at >= ? AND target_bundle_id IS NOT NULL AND target_bundle_id <> ''"
        let sql = "SELECT target_bundle_id, COUNT(*) AS n FROM history" + scope + " GROUP BY target_bundle_id ORDER BY n DESC"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        if let date { sqlite3_bind_double(statement, 1, date.timeIntervalSince1970) }

        var result: [HistoryAppCount] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bundle = sqlite3_column_text(statement, 0) else { continue }
            result.append(HistoryAppCount(bundleID: String(cString: bundle), count: Int(sqlite3_column_int(statement, 1))))
        }
        return result
    }

    public func metrics(since date: Date?) async throws -> [HistoryMetricPoint] {
        let db = try connection()
        let sql = "SELECT created_at, duration_seconds, MAX(word_count, 0) FROM history" + rangeClause(date) + " ORDER BY created_at ASC"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        if let date { sqlite3_bind_double(statement, 1, date.timeIntervalSince1970) }

        var points: [HistoryMetricPoint] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            points.append(HistoryMetricPoint(
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                durationSeconds: sqlite3_column_double(statement, 1),
                words: Int(sqlite3_column_int(statement, 2))
            ))
        }
        return points
    }

    /// Shared row decoder for every SELECT below (column order:
    /// id, raw_text, refined_text, target_bundle_id, outcome, created_at,
    /// duration_seconds).
    private func decodeRow(_ statement: OpaquePointer?) -> HistoryItem? {
        guard
            let idText = sqlite3_column_text(statement, 0),
            let rawText = sqlite3_column_text(statement, 1),
            let outcomeText = sqlite3_column_text(statement, 4),
            let id = UUID(uuidString: String(cString: idText))
        else { return nil }

        return HistoryItem(
            id: id,
            rawText: String(cString: rawText),
            refinedText: sqlite3_column_text(statement, 2).map { String(cString: $0) },
            targetBundleID: sqlite3_column_text(statement, 3).map { String(cString: $0) },
            outcome: String(cString: outcomeText),
            durationSeconds: sqlite3_column_double(statement, 6),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
        )
    }

    public func save(_ item: HistoryItem) async throws {
        let db = try connection()
        let sql = "INSERT INTO history (id, raw_text, refined_text, target_bundle_id, outcome, created_at, duration_seconds, word_count) VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, item.id.uuidString, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, item.rawText, -1, sqliteTransient)
        if let refined = item.refinedText {
            sqlite3_bind_text(statement, 3, refined, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 3)
        }
        if let bundleID = item.targetBundleID {
            sqlite3_bind_text(statement, 4, bundleID, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 4)
        }
        sqlite3_bind_text(statement, 5, item.outcome, -1, sqliteTransient)
        sqlite3_bind_double(statement, 6, item.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 7, item.durationSeconds)
        sqlite3_bind_int(statement, 8, Int32(TranscriptMetrics.wordCount(item.insertedText)))

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    public func search(query: String, limit: Int) async throws -> [HistoryItem] {
        let db = try connection()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        let columns = "id, raw_text, refined_text, target_bundle_id, outcome, created_at, duration_seconds"
        let sql: String
        if trimmed.isEmpty {
            sql = "SELECT \(columns) FROM history ORDER BY created_at DESC LIMIT ?"
        } else {
            sql = """
            SELECT \(columns) FROM history
            WHERE raw_text LIKE ? ESCAPE '\\' OR refined_text LIKE ? ESCAPE '\\'
            ORDER BY created_at DESC LIMIT ?
            """
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        if trimmed.isEmpty {
            sqlite3_bind_int(statement, 1, Int32(limit))
        } else {
            let escaped = trimmed
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            let pattern = "%\(escaped)%"
            sqlite3_bind_text(statement, 1, pattern, -1, sqliteTransient)
            sqlite3_bind_text(statement, 2, pattern, -1, sqliteTransient)
            sqlite3_bind_int(statement, 3, Int32(limit))
        }

        var items: [HistoryItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let item = decodeRow(statement) { items.append(item) }
        }
        return items
    }

    public func items(since date: Date) async throws -> [HistoryItem] {
        let db = try connection()
        let sql = """
        SELECT id, raw_text, refined_text, target_bundle_id, outcome, created_at, duration_seconds
        FROM history WHERE created_at >= ? ORDER BY created_at DESC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)

        var items: [HistoryItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let item = decodeRow(statement) { items.append(item) }
        }
        return items
    }

    public func delete(id: UUID) async throws {
        let db = try connection()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM history WHERE id = ?", -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id.uuidString, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    public func deleteAll() async throws {
        let db = try connection()
        guard sqlite3_exec(db, "DELETE FROM history", nil, nil, nil) == SQLITE_OK else {
            throw StoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
    }
}
