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

    /// `interrupted` is written only by stale-lock recovery (`reclaim`), which closes the
    /// orphaned `running` task of a dead or expired holder; the schema admits it from v1.
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

    /// A mutation lock's row in `locks`, as read back. The holder's identity is the pair
    /// (pid, acquiredAt): a recycled PID is indistinguishable from a live holder by design
    /// (schema v1 is frozen), bounded by the 30-minute TTL.
    public struct LockInfo: Equatable, Sendable {
        public let machine: String
        public let pid: Int32
        public let acquiredAt: Date
        public let taskID: Int64?
    }

    /// What `unlock(machine:)` did. A live in-TTL holder throws instead.
    public enum UnlockOutcome: Equatable, Sendable {
        case nothingToUnlock
        /// `orphanClosed` says whether a `running` task was actually closed as
        /// `interrupted` — a NULL, purged or already-closed `task_id` releases the
        /// lock without touching any task, and the CLI must not claim otherwise.
        case released(LockInfo, orphanClosed: Bool)
        /// The lock row's timestamp no longer parsed: treated as stale and removed —
        /// leaving it would make the machine refuse mutations forever. Same
        /// `orphanClosed` contract as `released`.
        case releasedCorrupt(orphanClosed: Bool)
    }

    private static let schemaVersion: Int32 = 1
    /// A lock older than this is stale even if its holder still runs (AD-12): the arbiter
    /// against a recycled PID and against a wedged action holding a machine hostage.
    public static let lockTTL: TimeInterval = 30 * 60
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
    /// Liveness probe for lock holders — injectable because a really-dead PID cannot be
    /// fabricated deterministically in tests. The default asks the kernel.
    private let isProcessAlive: (pid_t) -> Bool

    /// `kill(pid, 0)` probes existence without delivering a signal: success or `EPERM`
    /// means the process runs; only `ESRCH` means it is gone. A degenerate pid is dead
    /// by fiat: `kill(0, 0)` would probe the caller's own process group and report any
    /// corrupt row's holder as alive.
    public static func defaultProcessProbe(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno != ESRCH
    }

    public init(path: String = HistoryStore.defaultPath,
                isProcessAlive: @escaping (pid_t) -> Bool = HistoryStore.defaultProcessProbe) throws {
        self.isProcessAlive = isProcessAlive
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
        // Only a `running` row can be finished: a TTL takeover may close this very task
        // as `interrupted` while its original holder still runs, and the holder's late
        // finish must not rewrite that verdict — `interrupted` is sticky.
        let statement = try prepare("""
        UPDATE tasks SET finished_at = ?1, status = ?2, output = ?3 WHERE id = ?4 AND status = ?5;
        """)
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, Self.iso8601.string(from: now))
        try bind(statement, 2, status.rawValue)
        try bind(statement, 3, output)
        try bind(statement, 4, id)
        try bind(statement, 5, TaskStatus.running.rawValue)
        try step(statement)
        // A vanished or already-closed row must not pass off a lost completion as a
        // success — the seam degrades this into its stderr warning.
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

    // MARK: - Locks

    /// Takes the machine's mutation lock, or throws the contention refusal naming the
    /// holder. Atomicity comes from `BEGIN IMMEDIATE` — never from the NSLock, which
    /// only serializes within one process while app and CLI are two, and `update --all`
    /// opens N stores under a single PID.
    ///
    /// A stale lock — holder dead (`ESRCH`) or `acquired_at` beyond the TTL even with the
    /// holder alive — is reclaimed in the same transaction: its orphaned `running` task is
    /// closed as `interrupted` (tolerantly: an absent or already-closed row passes), the
    /// row replaced.
    public func acquireLock(machine: String, pid: Int32, now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE;")
        do {
            switch try readLockRow(machine: machine) {
            case .none:
                break
            case .readable(let holder):
                guard isStale(holder, now: now) else {
                    throw LockContentionError("cannot run on \(machine): held by pid \(holder.pid) since \(Self.iso8601String(from: holder.acquiredAt))")
                }
                try reclaim(machine: machine, taskID: holder.taskID,
                            note: "interrupted: lock held by pid \(holder.pid) since \(Self.iso8601String(from: holder.acquiredAt)) was reclaimed (process dead or lock expired)",
                            now: now)
            case .corrupt(let pid, let taskID):
                // An unreadable timestamp cannot prove the lock fresh: stale by doctrine,
                // or the machine would refuse every mutation forever.
                try reclaim(machine: machine, taskID: taskID,
                            note: "interrupted: unreadable lock held by pid \(pid) was reclaimed (corrupt timestamp)",
                            now: now)
            }
            let statement = try prepare("""
            INSERT INTO locks (machine, pid, acquired_at, task_id) VALUES (?1, ?2, ?3, NULL);
            """)
            defer { sqlite3_finalize(statement) }
            try bind(statement, 1, machine)
            try bind(statement, 2, pid)
            try bind(statement, 3, Self.iso8601String(from: now))
            try step(statement)
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Ties the lock to the journal entry opened after acquisition, so a takeover can
    /// close the right orphan. Scoped to (machine, pid): never rewrites a lock that a
    /// TTL takeover has already handed to someone else.
    public func attachTask(machine: String, pid: Int32, taskID: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("UPDATE locks SET task_id = ?1 WHERE machine = ?2 AND pid = ?3;")
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, taskID)
        try bind(statement, 2, machine)
        try bind(statement, 3, pid)
        try step(statement)
    }

    /// Releases by deleting the row — only the caller's own (machine, pid) pair, so a
    /// long-overrun action whose lock was reclaimed cannot free the new holder's.
    /// `acquiredAt` narrows further to the caller's own acquisition: (machine, pid)
    /// alone cannot tell an overrun action from its *own* TTL takeover in the same
    /// process, and its late release would otherwise free the reacquired lock.
    public func releaseLock(machine: String, pid: Int32, acquiredAt: Date? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare(acquiredAt == nil
            ? "DELETE FROM locks WHERE machine = ?1 AND pid = ?2;"
            : "DELETE FROM locks WHERE machine = ?1 AND pid = ?2 AND acquired_at = ?3;")
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, machine)
        try bind(statement, 2, pid)
        if let acquiredAt {
            try bind(statement, 3, Self.iso8601String(from: acquiredAt))
        }
        try step(statement)
    }

    public func currentLock(machine: String) throws -> LockInfo? {
        lock.lock(); defer { lock.unlock() }
        // Pure read: corruption stays an error here — only the reclaim paths
        // (acquisition, unlock) may treat an unreadable row as stale.
        switch try readLockRow(machine: machine) {
        case .none: return nil
        case .readable(let info): return info
        case .corrupt:
            throw HPMError("hpm.db: lock row for \(machine) is unreadable (bad timestamp)")
        }
    }

    /// The testable core of `hpm unlock`: refuses while the holder is alive and within
    /// the TTL (the error names who and since when), releases a stale lock through the
    /// same reclaim routine as acquisition, and reports an absent lock as nothing to do.
    public func unlock(machine: String, now: Date = Date()) throws -> UnlockOutcome {
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE;")
        do {
            switch try readLockRow(machine: machine) {
            case .none:
                try exec("COMMIT;")
                return .nothingToUnlock
            case .readable(let holder):
                guard isStale(holder, now: now) else {
                    throw HPMError("cannot unlock \(machine): held by pid \(holder.pid) since \(Self.iso8601String(from: holder.acquiredAt)) and that process is still running")
                }
                let orphanClosed = try reclaim(machine: machine, taskID: holder.taskID,
                                               note: "interrupted: lock held by pid \(holder.pid) since \(Self.iso8601String(from: holder.acquiredAt)) was reclaimed (process dead or lock expired)",
                                               now: now)
                try exec("COMMIT;")
                return .released(holder, orphanClosed: orphanClosed)
            case .corrupt(let pid, let taskID):
                let orphanClosed = try reclaim(machine: machine, taskID: taskID,
                                               note: "interrupted: unreadable lock held by pid \(pid) was reclaimed (corrupt timestamp)",
                                               now: now)
                try exec("COMMIT;")
                return .releasedCorrupt(orphanClosed: orphanClosed)
            }
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private func isStale(_ holder: LockInfo, now: Date) -> Bool {
        // A negative age — acquired "in the future", after a clock step back — could
        // never exceed the TTL and would make the lock eternal: stale as well.
        let age = now.timeIntervalSince(holder.acquiredAt)
        return !isProcessAlive(holder.pid) || age < 0 || age > Self.lockTTL
    }

    /// What the `locks` row for a machine holds. `corrupt` keeps the columns that still
    /// read (pid, task_id) so the reclaim paths can close the orphan and say who held it.
    private enum LockReading {
        case none
        case readable(LockInfo)
        case corrupt(pid: Int32, taskID: Int64?)
    }

    /// Assumes the NSLock is held.
    private func readLockRow(machine: String) throws -> LockReading {
        let statement = try prepare("SELECT machine, pid, acquired_at, task_id FROM locks WHERE machine = ?1;")
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, machine)
        let code = sqlite3_step(statement)
        guard code == SQLITE_ROW else {
            guard code == SQLITE_DONE else { throw sqliteError("hpm.db") }
            return .none
        }
        let pid = sqlite3_column_int(statement, 1)
        let taskID: Int64? = sqlite3_column_type(statement, 3) == SQLITE_NULL
            ? nil : sqlite3_column_int64(statement, 3)
        guard let acquiredAt = Self.iso8601.date(from: column(statement, 2)) else {
            return .corrupt(pid: pid, taskID: taskID)
        }
        return .readable(LockInfo(machine: column(statement, 0),
                                  pid: pid,
                                  acquiredAt: acquiredAt,
                                  taskID: taskID))
    }

    /// Assumes the NSLock is held and a transaction is open. Closes the orphan through a
    /// tolerant UPDATE rather than `finish`, which throws on a missing row: a NULL
    /// `task_id`, a purged row or an already-closed one must all pass silently. Returns
    /// whether a `running` task was actually closed, so `unlock` can report honestly.
    @discardableResult
    private func reclaim(machine: String, taskID: Int64?, note: String, now: Date) throws -> Bool {
        var orphanClosed = false
        if let taskID {
            let statement = try prepare("""
            UPDATE tasks SET finished_at = ?1, status = ?2, output = ?3
            WHERE id = ?4 AND status = ?5;
            """)
            defer { sqlite3_finalize(statement) }
            try bind(statement, 1, Self.iso8601String(from: now))
            try bind(statement, 2, TaskStatus.interrupted.rawValue)
            try bind(statement, 3, note)
            try bind(statement, 4, taskID)
            try bind(statement, 5, TaskStatus.running.rawValue)
            try step(statement)
            orphanClosed = sqlite3_changes(db) > 0
        }
        let removal = try prepare("DELETE FROM locks WHERE machine = ?1;")
        defer { sqlite3_finalize(removal) }
        try bind(removal, 1, machine)
        try step(removal)
        return orphanClosed
    }

    // MARK: - Schema

    private func migrate(from version: Int32) throws {
        guard version < 1 else { return }
        // v1: the task journal plus the lock table. The schema is 1.2's and frozen;
        // acquisition, TTL and takeover live in the Locks section above, same v1.
        // `task_id` ties the lock to the task a takeover closes as `interrupted`.
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
