import Foundation
import SQLite3

/// `sqlite3_bind_text` needs SQLITE_TRANSIENT (make a private copy) because
/// Swift string UTF-8 buffers don't outlive the call; the C macro doesn't
/// import, so rebuild it.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite-backed `HistoryStore`.
///
/// Search is a plain indexed-scan `LIKE '%query%'` rather than FTS5: the
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

        db = Connection(handle: handle)
        return handle
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
        let sql = "INSERT INTO history (id, raw_text, refined_text, target_bundle_id, outcome, created_at, duration_seconds) VALUES (?, ?, ?, ?, ?, ?, ?)"
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
