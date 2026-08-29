import XCTest
import SQLite3
@testable import HomePortKit

/// Covers the I/O matrix on the store side: schema creation, begin/finish, ISO 8601 UTC,
/// ordering, machine filter, both purge axes, reopening, the newer-version guard and
/// concurrent writers — the AD-7 foundation 1.3, epic 2 and epic 3 extend by migration.
final class HistoryStoreTests: XCTestCase {
    private var root: String!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        root = NSTemporaryDirectory() + "hpm-history-\(UUID().uuidString)"
        dbPath = root + "/state/hpm.db"
    }

    override func tearDown() {
        // WAL leaves -wal/-shm companions behind: remove the whole directory.
        try? FileManager.default.removeItem(atPath: root)
        super.tearDown()
    }

    /// Raw peek at the database, bypassing the store — schema assertions must not trust
    /// the code under test.
    private func rawQuery(_ sql: String) throws -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else { throw HPMError("cannot open \(dbPath!)") }
        defer { sqlite3_close_v2(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw HPMError("cannot prepare \(sql)")
        }
        var values: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            values.append(sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "")
        }
        return values
    }

    private func rawExec(_ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else { throw HPMError("cannot open \(dbPath!)") }
        defer { sqlite3_close_v2(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw HPMError("cannot exec \(sql)") }
    }

    // MARK: - First launch / schema

    func testFirstOpenCreatesDirectoriesAndSchema() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbPath))
        _ = try HistoryStore(path: dbPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbPath))
        XCTAssertEqual(try rawQuery("PRAGMA journal_mode;"), ["wal"])
        XCTAssertEqual(try rawQuery("PRAGMA user_version;"), ["4"])
        XCTAssertEqual(try rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('tasks','locks','event_cursors','notified_markers') ORDER BY name;"),
                       ["event_cursors", "locks", "notified_markers", "tasks"])
        XCTAssertEqual(try rawQuery("SELECT name FROM pragma_table_info('locks') ORDER BY cid;"),
                       ["machine", "pid", "acquired_at", "task_id"])
        XCTAssertEqual(try rawQuery("SELECT name FROM pragma_table_info('event_cursors') ORDER BY cid;"),
                       ["machine", "epoch", "last_id", "updated_at"])
        XCTAssertEqual(try rawQuery("SELECT name FROM pragma_table_info('notified_markers') ORDER BY cid;"),
                       ["machine", "epoch", "notified_up_to", "updated_at"])
    }

    /// A base created by an earlier hpm must *receive* every later step, and keep
    /// everything v1 put in it. The migration used to be a single
    /// `guard version < 1 else { return }`: with steps behind it, that early return would
    /// have skipped them for precisely the databases that need them — every one already
    /// in use.
    func testAV1DatabaseIsMigratedToTheLatestSchemaWithoutLosingAnything() throws {
        // A genuine v1 base, written without the code under test.
        try FileManager.default.createDirectory(atPath: (dbPath as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try rawExec("""
        CREATE TABLE tasks (
            id INTEGER PRIMARY KEY AUTOINCREMENT, started_at TEXT NOT NULL, finished_at TEXT,
            machine TEXT NOT NULL, action TEXT NOT NULL, status TEXT NOT NULL,
            output TEXT NOT NULL DEFAULT ''
        );
        CREATE TABLE locks (
            machine TEXT PRIMARY KEY, pid INTEGER NOT NULL, acquired_at TEXT NOT NULL, task_id INTEGER
        );
        INSERT INTO tasks (started_at, machine, action, status, output)
        VALUES ('2026-08-24T10:00:00Z', 'raspcorse', 'backup', 'success', 'done');
        PRAGMA user_version = 1;
        """)

        let store = try HistoryStore(path: dbPath)

        XCTAssertEqual(try rawQuery("PRAGMA user_version;"), ["4"])
        XCTAssertEqual(try rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('event_cursors', 'notified_markers') ORDER BY name;"),
                       ["event_cursors", "notified_markers"])
        XCTAssertEqual(try store.tasks().map(\.action), ["backup"],
                       "the v1 journal survives the migration untouched")
        XCTAssertNil(try store.eventCursor(machine: "raspcorse"))
        try store.setEventCursor(EventCursor(epoch: "epoch-1", id: 7), machine: "raspcorse")
        XCTAssertEqual(try store.eventCursor(machine: "raspcorse"), EventCursor(epoch: "epoch-1", id: 7))
        XCTAssertNil(try store.notifiedMarker(machine: "raspcorse"))
        try store.setNotifiedMarker(NotifiedMarker(epoch: "epoch-1", notifiedUpTo: 7), machine: "raspcorse")
        XCTAssertEqual(try store.notifiedMarker(machine: "raspcorse"), NotifiedMarker(epoch: "epoch-1", notifiedUpTo: 7))
    }

    func testReopenDoesNotRemigrate() throws {
        let store = try HistoryStore(path: dbPath)
        let id = try store.begin(action: "backup", machine: "raspcorse")
        try store.finish(id: id, status: .success, output: "done")

        let reopened = try HistoryStore(path: dbPath)
        XCTAssertEqual(try rawQuery("PRAGMA user_version;"), ["4"])
        XCTAssertEqual(try reopened.tasks().count, 1)
    }

    func testNewerSchemaVersionRefusedAndUntouched() throws {
        _ = try HistoryStore(path: dbPath)
        let id = try HistoryStore(path: dbPath).begin(action: "backup", machine: "raspcorse")
        // Put the base in a non-WAL journal mode before the refusal: "untouched" also
        // means the WAL pragma must not run — this pins the guard-before-pragma ordering
        // in `init`, which nothing else can observe (the WAL fixture would mask it).
        try rawExec("PRAGMA journal_mode = DELETE;")
        try rawExec("PRAGMA user_version = 99;")

        XCTAssertThrowsError(try HistoryStore(path: dbPath)) { error in
            XCTAssertTrue("\(error)".contains("99"), "error should name the newer version: \(error)")
        }
        // Untouched: version, rows and journal mode survive the refusal.
        XCTAssertEqual(try rawQuery("PRAGMA user_version;"), ["99"])
        XCTAssertEqual(try rawQuery("SELECT id FROM tasks;"), ["\(id)"])
        XCTAssertEqual(try rawQuery("PRAGMA journal_mode;"), ["delete"])
    }

    func testUnwritableStateDirectoryThrows() throws {
        // A file where the parent directory should be makes createDirectory fail.
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root + "/state", contents: nil)
        XCTAssertThrowsError(try HistoryStore(path: dbPath))
    }

    // MARK: - begin / finish

    func testBeginOpensRunningEntryAndFinishClosesIt() throws {
        let store = try HistoryStore(path: dbPath)
        let id = try store.begin(action: "backup", machine: "raspcorse")

        let running = try XCTUnwrap(store.task(id: id))
        XCTAssertEqual(running.status, .running)
        XCTAssertNil(running.finishedAt)

        try store.finish(id: id, status: .success, output: "line 1\nline 2")
        let done = try XCTUnwrap(store.task(id: id))
        XCTAssertEqual(done.status, .success)
        XCTAssertEqual(done.machine, "raspcorse")
        XCTAssertEqual(done.action, "backup")
        XCTAssertEqual(done.output, "line 1\nline 2")
        XCTAssertNotNil(done.finishedAt)
    }

    func testTimestampsStoredAsISO8601UTC() throws {
        let store = try HistoryStore(path: dbPath)
        let instant = Date(timeIntervalSince1970: 1_755_945_600) // 2025-08-23T10:40:00Z
        let id = try store.begin(action: "backup", machine: "raspcorse", now: instant)
        try store.finish(id: id, status: .success, output: "", now: instant)

        XCTAssertEqual(try rawQuery("SELECT started_at FROM tasks WHERE id = \(id);"),
                       ["2025-08-23T10:40:00Z"])
        XCTAssertEqual(try rawQuery("SELECT finished_at FROM tasks WHERE id = \(id);"),
                       ["2025-08-23T10:40:00Z"])
    }

    // MARK: - Reading

    func testTasksSortedNewestFirst() throws {
        let store = try HistoryStore(path: dbPath)
        for (action, machine) in [("backup", "raspcorse"), ("restart", "otherpi"), ("doctor", "raspcorse")] {
            let id = try store.begin(action: action, machine: machine)
            try store.finish(id: id, status: .success, output: "")
        }
        XCTAssertEqual(try store.tasks().map(\.action), ["doctor", "restart", "backup"])
    }

    func testTasksFilteredByExactMachineName() throws {
        let store = try HistoryStore(path: dbPath)
        _ = try store.begin(action: "backup", machine: "raspcorse")
        _ = try store.begin(action: "restart", machine: "otherpi")
        _ = try store.begin(action: "doctor", machine: "raspcorse")

        XCTAssertEqual(try store.tasks(machine: "raspcorse").map(\.action), ["doctor", "backup"])
        XCTAssertEqual(try store.tasks(machine: "otherpi").map(\.action), ["restart"])
    }

    func testUnknownMachineYieldsEmptyListNotError() throws {
        let store = try HistoryStore(path: dbPath)
        _ = try store.begin(action: "backup", machine: "raspcorse")
        XCTAssertEqual(try store.tasks(machine: "ghost"), [])
    }

    func testLimitCapsTheList() throws {
        let store = try HistoryStore(path: dbPath)
        for i in 0..<10 { _ = try store.begin(action: "a\(i)", machine: "raspcorse") }
        XCTAssertEqual(try store.tasks(limit: 3).count, 3)
    }

    func testWildLimitsAreClampedNotTrapped() throws {
        let store = try HistoryStore(path: dbPath)
        for i in 0..<3 { _ = try store.begin(action: "a\(i)", machine: "raspcorse") }
        // Beyond Int32.max: must not trap on conversion, just act as "everything".
        XCTAssertEqual(try store.tasks(limit: 3_000_000_000).count, 3)
        // Zero or negative: clamped to 1, never an unbounded SQLite LIMIT.
        XCTAssertEqual(try store.tasks(limit: 0).count, 1)
        XCTAssertEqual(try store.tasks(limit: -1).count, 1)
    }

    /// Pins the app's only read shape: `includeOutput: false` swaps the output column
    /// for a `''` placeholder, and every other field must survive that projection.
    func testListWithoutOutputKeepsEveryOtherField() throws {
        let store = try HistoryStore(path: dbPath)
        let id = try store.begin(action: "backup", machine: "raspcorse")
        try store.finish(id: id, status: .success, output: "line 1\nline 2")

        let entry = try XCTUnwrap(store.tasks(includeOutput: false).first)
        XCTAssertEqual(entry.id, id)
        XCTAssertEqual(entry.machine, "raspcorse")
        XCTAssertEqual(entry.action, "backup")
        XCTAssertEqual(entry.status, .success)
        XCTAssertNotNil(entry.finishedAt)
        XCTAssertEqual(entry.output, "", "the list projection must not load outputs")
        // The column itself is untouched: the full read still returns it.
        XCTAssertEqual(try store.tasks().first?.output, "line 1\nline 2")
    }

    func testUnknownTaskIdIsNil() throws {
        let store = try HistoryStore(path: dbPath)
        XCTAssertNil(try store.task(id: 12_345))
    }

    /// Nothing writes `interrupted` before story 1.3, but the read contract 1.3 will
    /// rely on is pinned now: a raw `interrupted` row parses like any other status.
    func testInterruptedRowsReadBack() throws {
        let store = try HistoryStore(path: dbPath)
        _ = try store.begin(action: "backup", machine: "raspcorse")
        try rawExec("UPDATE tasks SET status = 'interrupted', finished_at = '2025-08-23T10:40:00Z';")

        let entry = try XCTUnwrap(store.tasks().first)
        XCTAssertEqual(entry.status, .interrupted)
        XCTAssertNotNil(entry.finishedAt)
    }

    func testFinishOnMissingRowThrowsInsteadOfSilentNoOp() throws {
        let store = try HistoryStore(path: dbPath)
        XCTAssertThrowsError(try store.finish(id: 12_345, status: .success, output: "")) { error in
            XCTAssertTrue("\(error)".contains("12345"), "error should name the missing id: \(error)")
        }
    }

    /// `interrupted` is sticky: a TTL takeover can close a task whose original holder
    /// still runs, and that holder's late `finish` must not rewrite the verdict.
    func testFinishCannotRewriteAnInterruptedTask() throws {
        let store = try HistoryStore(path: dbPath)
        let id = try store.begin(action: "backup", machine: "raspcorse")
        try rawExec("UPDATE tasks SET status = 'interrupted', finished_at = '2025-08-23T10:40:00Z' WHERE id = \(id);")

        XCTAssertThrowsError(try store.finish(id: id, status: .success, output: "late")) { error in
            XCTAssertTrue("\(error)".contains("\(id)"), "\(error)")
        }
        let entry = try XCTUnwrap(store.task(id: id))
        XCTAssertEqual(entry.status, .interrupted)
        XCTAssertNotEqual(entry.output, "late")
    }

    /// Corruption is an error, not absence: a row that no longer parses must not
    /// silently shrink listings or make `task(id:)` deny the row exists.
    func testCorruptRowSurfacesAsErrorNotAbsence() throws {
        let store = try HistoryStore(path: dbPath)
        let id = try store.begin(action: "backup", machine: "raspcorse")
        try rawExec("UPDATE tasks SET status = 'garbled' WHERE id = \(id);")

        XCTAssertThrowsError(try store.tasks())
        XCTAssertThrowsError(try store.task(id: id))
    }

    /// Same doctrine for finished_at: a non-empty value that no longer parses must not
    /// silently read back as "never finished".
    func testCorruptFinishedAtSurfacesAsErrorNotRunning() throws {
        let store = try HistoryStore(path: dbPath)
        let id = try store.begin(action: "backup", machine: "raspcorse")
        try store.finish(id: id, status: .success, output: "")
        try rawExec("UPDATE tasks SET finished_at = 'not-a-date' WHERE id = \(id);")

        XCTAssertThrowsError(try store.tasks())
        XCTAssertThrowsError(try store.task(id: id))
    }

    // MARK: - Purge

    func testPurgeRemovesEntriesOlderThanOneYear() throws {
        let store = try HistoryStore(path: dbPath)
        let now = Date()
        let old = now.addingTimeInterval(-400 * 24 * 3600)
        let recent = now.addingTimeInterval(-3600)
        let oldId = try store.begin(action: "old", machine: "raspcorse", now: old)
        try store.finish(id: oldId, status: .success, output: "", now: old)
        let recentId = try store.begin(action: "recent", machine: "raspcorse", now: recent)
        try store.finish(id: recentId, status: .success, output: "", now: recent)

        XCTAssertEqual(try store.purge(now: now), 1)
        XCTAssertEqual(try store.tasks().map(\.action), ["recent"])
    }

    func testPurgeCapsAtTenThousandEntries() throws {
        let store = try HistoryStore(path: dbPath)
        let now = Date()
        for i in 0..<10_005 {
            _ = try store.begin(action: "task-\(i)", machine: "raspcorse", now: now)
        }
        XCTAssertEqual(try store.purge(now: now), 5)
        XCTAssertEqual(try rawQuery("SELECT COUNT(*) FROM tasks;"), ["10000"])
        // The most recent survive: the newest entry is still there.
        XCTAssertEqual(try store.tasks(limit: 1).first?.action, "task-10004")
    }

    // MARK: - Events cursor corruption

    /// Same doctrine as the task journal's corrupt rows: a `last_id` that nothing here
    /// ever writes — negative — is corruption, not "never read", and must surface as an
    /// error rather than being silently treated as an absent cursor.
    func testANegativeLastIDSurfacesAsErrorNotAbsence() throws {
        let store = try HistoryStore(path: dbPath)
        try store.setEventCursor(EventCursor(epoch: "epoch-1", id: 7), machine: "raspcorse")
        try rawExec("UPDATE event_cursors SET last_id = -1 WHERE machine = 'raspcorse';")

        XCTAssertThrowsError(try store.eventCursor(machine: "raspcorse"))
    }

    // MARK: - Concurrency

    func testTwoStoresWriteConcurrentlyWithoutLoss() throws {
        let first = try HistoryStore(path: dbPath)
        let second = try HistoryStore(path: dbPath)
        let writesPerStore = 50

        DispatchQueue.concurrentPerform(iterations: writesPerStore * 2) { i in
            let store = i % 2 == 0 ? first : second
            if let id = try? store.begin(action: "task-\(i)", machine: "raspcorse") {
                try? store.finish(id: id, status: .success, output: "")
            }
        }

        let entries = try first.tasks(limit: 1_000)
        XCTAssertEqual(entries.count, writesPerStore * 2)
        XCTAssertTrue(entries.allSatisfy { $0.status == .success })
    }
}
