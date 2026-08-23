import Foundation
import SQLite3

/// SQLite's "copy this string now" destructor. It is a C macro (`SQLITE_TRANSIENT`), not a
/// symbol, so it is unavailable to Swift and has to be reconstructed — the standard idiom.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Sole owner of the Mac-side state database (~/.local/state/hpm/hpm.db). Every frontend
/// and the manager go through this API; no other code opens the file. Schema changes only
/// ever happen through `PRAGMA user_version` migrations, never through parallel tables.
///
/// WAL plus a non-zero `busy_timeout` are what let the app and the CLI — two separate
/// processes — write at the same time without one erroring out from the other's lock. The
/// internal `NSLock` is a different concern: it serializes calls made concurrently *within*
/// one process (`forEachMachine` threads, the app's `Task.detached`).
public final class HistoryStore: @unchecked Sendable {
    public static let defaultPath = "~/.local/state/hpm/hpm.db"

    /// `interrupted` belongs to story 1.3 (stale-lock recovery); nothing writes it here,
    /// but the schema admits it from v1 so 1.3 needs no migration to close a dead task.
    public enum TaskStatus: String, Sendable {
        case running, success, failure, interrupted
    }

    /// One journal line. `id` is the rowid, so `DataTable` can use it directly. The entry
    /// opens as `running` when the action starts and is closed by `finish` — the in-flight
    /// row is what lets 1.3 close a dead process's task as `interrupted`.
    public struct TaskEntry: Identifiable, Equatable, Sendable {
        public let id: Int64
        public let startedAt: Date
        public let finishedAt: Date?
        public let machine: String
        public let action: String
        public let status: TaskStatus
        public let output: String
    }

    private static let schemaVersion: Int32 = 1
    /// Retention policy (NFR7): age first, then a hard cap. Enforced only by `purge(now:)`,
    /// which only the app ever calls, at startup.
    private static let retentionSeconds: TimeInterval = 365 * 24 * 3600
    /// Public because it is also the ceiling every consumer shares: the CLI's `--limit`
    /// guard, the read clamp below, and the app's full reload all mean *this* number.
    public static let retentionCap = 10_000

    /// Timestamps are stored as ISO 8601 UTC text — it also compares correctly as text,
    /// so the purge's age cutoff is a plain string comparison. The `timestampFormatter`
    /// of `Manager+Backup` is local-time and file-name-shaped, so it cannot be reused.
    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    public static func iso8601String(from date: Date) -> String {
        iso8601.string(from: date)
    }

    private let lock = NSLock()
    private let db: OpaquePointer

    public init(path: String = HistoryStore.defaultPath) throws {
        let expanded = expandPath(path)
        let dir = (expanded as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            throw HPMError("cannot create \(dir): \(error.localizedDescription)")
        }

        var handle: OpaquePointer?
        guard sqlite3_open(expanded, &handle) == SQLITE_OK, let opened = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close_v2(handle)
            throw HPMError("cannot open \(expanded): \(message)")
        }
        db = opened
        // Armed before any statement runs: the very first `PRAGMA journal_mode=WAL` can
        // already collide with another process opening the same base (app + CLI at first
        // launch), and without the timeout that collision would fail the init outright.
        sqlite3_busy_timeout(opened, 5_000)
        do {
            // The version guard runs before the WAL pragma: a base from a newer hpm
            // must stay untouched, and flipping its journal mode counts as touching.
            let version = try userVersion()
            guard version <= Self.schemaVersion else {
                throw HPMError("""
                hpm.db is at schema version \(version), newer than this hpm understands \
                (\(Self.schemaVersion)) — update hpm before touching it
                """)
            }
            try exec("PRAGMA journal_mode=WAL;")
            try migrate(from: version)
        } catch {
            sqlite3_close_v2(opened)
            throw error
        }
    }

    deinit {
        sqlite3_close_v2(db)
    }

    // MARK: - Journal

    /// Opens the entry as `running`; `finish` closes it. A crash in between leaves an
    /// orphaned `running` row — assumed, that is exactly what story 1.3 reclaims.
    @discardableResult
    public func begin(action: String, machine: String, now: Date = Date()) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("""
        INSERT INTO tasks (started_at, machine, action, status, output)
        VALUES (?1, ?2, ?3, ?4, '');
        """)
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, Self.iso8601.string(from: now))
        try bind(statement, 2, machine)
        try bind(statement, 3, action)
        try bind(statement, 4, TaskStatus.running.rawValue)
        try step(statement)
        return sqlite3_last_insert_rowid(db)
    }

    public func finish(id: Int64, status: TaskStatus, output: String, now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("""
        UPDATE tasks SET finished_at = ?1, status = ?2, output = ?3 WHERE id = ?4;
        """)
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, Self.iso8601.string(from: now))
        try bind(statement, 2, status.rawValue)
        try bind(statement, 3, output)
        try bind(statement, 4, id)
        try step(statement)
        // A vanished row (purged mid-action, external tampering) must not pass off a
        // lost completion as a success — 1.3 relies on finish actually landing.
        guard sqlite3_changes(db) > 0 else {
            throw HPMError("hpm.db: no task with id \(id) to finish")
        }
    }

    /// Newest first — `id DESC`: the rowid is monotonic (AUTOINCREMENT), so no date needs
    /// parsing. The machine filter takes the name as-is: the journal may hold machines no
    /// longer in the fleet, so there is no fleet validation and an unknown name just
    /// yields an empty list.
    public func tasks(machine: String? = nil, limit: Int = 50, includeOutput: Bool = true) throws -> [TaskEntry] {
        lock.lock(); defer { lock.unlock() }
        // Defensive clamp: a wild limit must neither trap on Int32 conversion nor
        // become an unbounded SQLite LIMIT; the retention cap is the natural ceiling.
        let limit = min(max(limit, 1), Self.retentionCap)
        // List consumers (the app's tables) never render output; skipping the column
        // keeps a journal full of long captures out of the process for good.
        let outputColumn = includeOutput ? "output" : "''"
        let statement: OpaquePointer
        if machine != nil {
            statement = try prepare("""
            SELECT id, started_at, finished_at, machine, action, status, \(outputColumn)
            FROM tasks WHERE machine = ?1 ORDER BY id DESC LIMIT ?2;
            """)
        } else {
            statement = try prepare("""
            SELECT id, started_at, finished_at, machine, action, status, \(outputColumn)
            FROM tasks ORDER BY id DESC LIMIT ?1;
            """)
        }
        defer { sqlite3_finalize(statement) }
        if let machine {
            try bind(statement, 1, machine)
            try bind(statement, 2, Int32(limit))
        } else {
            try bind(statement, 1, Int32(limit))
        }

        var entries: [TaskEntry] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            entries.append(try entry(from: statement))
            code = sqlite3_step(statement)
        }
        // BUSY or CORRUPT mid-iteration must surface, not pass a truncated list off
        // as a complete read.
        guard code == SQLITE_DONE else { throw sqliteError("hpm.db") }
        return entries
    }

    public func task(id: Int64) throws -> TaskEntry? {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("""
        SELECT id, started_at, finished_at, machine, action, status, output
        FROM tasks WHERE id = ?1;
        """)
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, id)
        let code = sqlite3_step(statement)
        if code == SQLITE_ROW { return try entry(from: statement) }
        // "No such row" is nil; a read error is an error, not a quiet nil.
        guard code == SQLITE_DONE else { throw sqliteError("hpm.db") }
        return nil
    }

    /// Age first, then the hard cap, as one transaction: both axes apply together or
    /// not at all, and the write lock is taken once (`BEGIN IMMEDIATE`) instead of
    /// twice. Returns how many rows were removed.
    @discardableResult
    public func purge(now: Date = Date()) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE;")
        do {
            var removed = 0

            let byAge = try prepare("DELETE FROM tasks WHERE started_at < ?1;")
            defer { sqlite3_finalize(byAge) }
            try bind(byAge, 1, Self.iso8601.string(from: now.addingTimeInterval(-Self.retentionSeconds)))
            try step(byAge)
            removed += Int(sqlite3_changes(db))

            let byVolume = try prepare("""
            DELETE FROM tasks WHERE id NOT IN (SELECT id FROM tasks ORDER BY id DESC LIMIT ?1);
            """)
            defer { sqlite3_finalize(byVolume) }
            try bind(byVolume, 1, Int32(Self.retentionCap))
            try step(byVolume)
            removed += Int(sqlite3_changes(db))

            try exec("COMMIT;")
            return removed
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    // MARK: - Schema

    private func migrate(from version: Int32) throws {
        guard version < 1 else { return }
        // v1: the task journal plus the lock table. 1.2 owns only the *schema* of
        // `locks`; acquisition, TTL and takeover are story 1.3 — nothing writes it here.
        // `task_id` ties the future lock to the task 1.3 will close as `interrupted`.
        // No index: NFR6 caps the base at < 10 machines and ≤ 10 000 rows.
        try exec("""
        CREATE TABLE IF NOT EXISTS tasks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            started_at TEXT NOT NULL,
            finished_at TEXT,
            machine TEXT NOT NULL,
            action TEXT NOT NULL,
            status TEXT NOT NULL,
            output TEXT NOT NULL DEFAULT ''
        );
        CREATE TABLE IF NOT EXISTS locks (
            machine TEXT PRIMARY KEY,
            pid INTEGER NOT NULL,
            acquired_at TEXT NOT NULL,
            task_id INTEGER
        );
        PRAGMA user_version = 1;
        """)
    }

    private func userVersion() throws -> Int32 {
        let statement = try prepare("PRAGMA user_version;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw sqliteError("cannot read user_version")
        }
        return sqlite3_column_int(statement, 0)
    }

    // MARK: - SQLite plumbing

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw sqliteError("hpm.db")
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw sqliteError("hpm.db")
        }
        return statement
    }

    private func step(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteError("hpm.db")
        }
    }

    // Bind results are checked like step results: a failed bind (OOM, bad index after
    // a schema evolution) would otherwise leave the parameter NULL and write a corrupt
    // row, or surface later as an unrelated step error.
    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String) throws {
        guard sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT) == SQLITE_OK else {
            throw sqliteError("hpm.db")
        }
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Int64) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
            throw sqliteError("hpm.db")
        }
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Int32) throws {
        guard sqlite3_bind_int(statement, index, value) == SQLITE_OK else {
            throw sqliteError("hpm.db")
        }
    }

    private func sqliteError(_ context: String) -> HPMError {
        HPMError("\(context): \(String(cString: sqlite3_errmsg(db)))")
    }

    private func column(_ statement: OpaquePointer, _ index: Int32) -> String {
        sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
    }

    /// A row that no longer parses (mangled timestamp, unknown status) is corruption,
    /// not absence: it must surface as an error rather than silently shrink a listing
    /// or make `task(id:)` claim the row does not exist.
    private func entry(from statement: OpaquePointer) throws -> TaskEntry {
        guard let startedAt = Self.iso8601.date(from: column(statement, 1)),
              let status = TaskStatus(rawValue: column(statement, 5)) else {
            throw HPMError("hpm.db: task row \(sqlite3_column_int64(statement, 0)) is unreadable (bad timestamp or unknown status)")
        }
        // Same doctrine for finished_at: empty means still running, but a non-empty
        // value that no longer parses must not read back as "never finished".
        let finishedText = column(statement, 2)
        let finishedAt: Date?
        if finishedText.isEmpty {
            finishedAt = nil
        } else if let parsed = Self.iso8601.date(from: finishedText) {
            finishedAt = parsed
        } else {
            throw HPMError("hpm.db: task row \(sqlite3_column_int64(statement, 0)) is unreadable (bad timestamp or unknown status)")
        }
        return TaskEntry(
            id: sqlite3_column_int64(statement, 0),
            startedAt: startedAt,
            finishedAt: finishedAt,
            machine: column(statement, 3),
            action: column(statement, 4),
            status: status,
            output: column(statement, 6)
        )
    }
}
