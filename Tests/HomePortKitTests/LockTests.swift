import XCTest
import SQLite3
@testable import HomePortKit

/// Covers the lock matrix on the store side (AD-12): atomic acquisition and release,
/// contention refusal naming the holder, the two-process acquisition race, takeover of
/// dead-process and TTL-expired locks with tolerant orphan closure, `unlock`, and the
/// frozen v1 schema. The liveness probe is injected: a really-dead PID cannot be
/// fabricated deterministically, so "dead" is a probe that says so.
final class LockTests: XCTestCase {
    private var root: String!
    private var dbPath: String!

    private let alive: (pid_t) -> Bool = { _ in true }
    private let dead: (pid_t) -> Bool = { _ in false }
    private let instant = Date(timeIntervalSince1970: 1_755_945_600) // 2025-08-23T10:40:00Z

    override func setUp() {
        super.setUp()
        root = NSTemporaryDirectory() + "hpm-locks-\(UUID().uuidString)"
        dbPath = root + "/hpm.db"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
        super.tearDown()
    }

    /// Raw peek bypassing the store — schema assertions must not trust the code under test.
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

    // MARK: - Acquisition and release

    func testAcquireInsertsRowAndReleaseDeletesIt() throws {
        let store = try HistoryStore(path: dbPath, isProcessAlive: alive)
        try store.acquireLock(machine: "raspcorse", pid: 111, now: instant)

        let held = try XCTUnwrap(store.currentLock(machine: "raspcorse"))
        XCTAssertEqual(held.machine, "raspcorse")
        XCTAssertEqual(held.pid, 111)
        XCTAssertEqual(held.acquiredAt, instant)
        XCTAssertNil(held.taskID)

        try store.releaseLock(machine: "raspcorse", pid: 111)
        XCTAssertNil(try store.currentLock(machine: "raspcorse"))
    }

    func testAttachTaskTiesLockToJournalEntry() throws {
        let store = try HistoryStore(path: dbPath, isProcessAlive: alive)
        let id = try store.begin(action: "backup", machine: "raspcorse")
        try store.acquireLock(machine: "raspcorse", pid: 111)
        try store.attachTask(machine: "raspcorse", pid: 111, taskID: id)
        XCTAssertEqual(try store.currentLock(machine: "raspcorse")?.taskID, id)
    }

    /// Release is scoped to the caller's own (machine, pid): an overrun action whose
    /// lock was reclaimed must not free the new holder's.
    func testReleaseOnlyDeletesTheCallersOwnLock() throws {
        let store = try HistoryStore(path: dbPath, isProcessAlive: alive)
        try store.acquireLock(machine: "raspcorse", pid: 111)
        try store.releaseLock(machine: "raspcorse", pid: 222)
        XCTAssertEqual(try store.currentLock(machine: "raspcorse")?.pid, 111)
    }

    func testLocksArePerMachine() throws {
        let store = try HistoryStore(path: dbPath, isProcessAlive: alive)
        try store.acquireLock(machine: "raspcorse", pid: 111)
        // A second machine locks freely while the first is held.
        try store.acquireLock(machine: "otherpi", pid: 111)
        XCTAssertEqual(try store.currentLock(machine: "raspcorse")?.pid, 111)
        XCTAssertEqual(try store.currentLock(machine: "otherpi")?.pid, 111)
    }

    // MARK: - Contention

    func testContentionRefusalNamesHolderAndSince() throws {
        let store = try HistoryStore(path: dbPath, isProcessAlive: alive)
        try store.acquireLock(machine: "raspcorse", pid: 111, now: instant)

        XCTAssertThrowsError(try store.acquireLock(machine: "raspcorse", pid: 222,
                                                   now: instant.addingTimeInterval(60))) { error in
            // Its own type: the seam rethrows contention but degrades any other
            // lock-machinery failure — the distinction is the contract.
            XCTAssertTrue(error is LockContentionError, "\(error)")
            XCTAssertTrue("\(error)".contains("held by pid 111"), "\(error)")
            XCTAssertTrue("\(error)".contains("since 2025-08-23T10:40:00Z"), "\(error)")
        }
        // The refusal leaves the lock untouched.
        XCTAssertEqual(try store.currentLock(machine: "raspcorse")?.pid, 111)
    }

    /// Two processes: two stores, one winner — atomicity comes from SQL, never from the
    /// per-store NSLock.
    func testAcquisitionRaceHasExactlyOneWinner() throws {
        let first = try HistoryStore(path: dbPath, isProcessAlive: alive)
        let second = try HistoryStore(path: dbPath, isProcessAlive: alive)

        let lock = NSLock()
        var winners = 0
        var refusals: [Error] = []
        DispatchQueue.concurrentPerform(iterations: 2) { i in
            let store = i == 0 ? first : second
            do {
                try store.acquireLock(machine: "raspcorse", pid: Int32(1000 + i))
                lock.lock(); winners += 1; lock.unlock()
            } catch {
                lock.lock(); refusals.append(error); lock.unlock()
            }
        }
        XCTAssertEqual(winners, 1)
        // The loser of the real overlapping race must get the contention refusal naming
        // the holder — never a raw SQLITE_BUSY: the store's busy_timeout outlives the
        // winner's short transaction, so the loser's BEGIN waits and then reads the row.
        XCTAssertEqual(refusals.count, 1)
        for refusal in refusals {
            XCTAssertTrue(refusal is LockContentionError, "\(refusal)")
            XCTAssertTrue("\(refusal)".contains("held by pid"), "\(refusal)")
        }
        XCTAssertNotNil(try first.currentLock(machine: "raspcorse"))
    }

    // MARK: - Stale takeover

    func testDeadHolderIsReclaimedAndOrphanClosedInterrupted() throws {
        let holderStore = try HistoryStore(path: dbPath, isProcessAlive: alive)
        let orphan = try holderStore.begin(action: "backup", machine: "raspcorse")
        try holderStore.acquireLock(machine: "raspcorse", pid: 4242, now: instant)
        try holderStore.attachTask(machine: "raspcorse", pid: 4242, taskID: orphan)

        // A second process whose probe sees the holder dead takes over immediately.
        let taker = try HistoryStore(path: dbPath, isProcessAlive: dead)
        try taker.acquireLock(machine: "raspcorse", pid: 5151, now: instant.addingTimeInterval(60))

        XCTAssertEqual(try taker.currentLock(machine: "raspcorse")?.pid, 5151)
        let closed = try XCTUnwrap(taker.task(id: orphan))
        XCTAssertEqual(closed.status, .interrupted)
        XCTAssertNotNil(closed.finishedAt)
        XCTAssertTrue(closed.output.contains("pid 4242"), closed.output)
    }

    func testExpiredTTLIsReclaimedEvenWithALiveHolder() throws {
        let store = try HistoryStore(path: dbPath, isProcessAlive: alive)
        let orphan = try store.begin(action: "update", machine: "raspcorse")
        try store.acquireLock(machine: "raspcorse", pid: 4242, now: instant)
        try store.attachTask(machine: "raspcorse", pid: 4242, taskID: orphan)

        // One second past the TTL: stale despite the probe saying alive.
        let later = instant.addingTimeInterval(HistoryStore.lockTTL + 1)
        try store.acquireLock(machine: "raspcorse", pid: 5151, now: later)

        XCTAssertEqual(try store.currentLock(machine: "raspcorse")?.pid, 5151)
        XCTAssertEqual(try store.task(id: orphan)?.status, .interrupted)
    }

    func testWithinTTLAndAliveIsStillHeld() throws {
        let store = try HistoryStore(path: dbPath, isProcessAlive: alive)
        try store.acquireLock(machine: "raspcorse", pid: 4242, now: instant)
        // One minute short of the TTL: still the holder's.
        let almost = instant.addingTimeInterval(HistoryStore.lockTTL - 60)
        XCTAssertThrowsError(try store.acquireLock(machine: "raspcorse", pid: 5151, now: almost))
    }

    /// A NULL task_id, a purged row and an already-closed one all pass silently: the
    /// takeover reclaims the lock without inventing an error — or rewriting history.
    func testMissingOrClosedOrphanIsTolerated() throws {
        let store = try HistoryStore(path: dbPath, isProcessAlive: dead)

        // NULL task_id.
        try store.acquireLock(machine: "raspcorse", pid: 100, now: instant)
        try store.acquireLock(machine: "raspcorse", pid: 200, now: instant)

        // task_id pointing at a purged (nonexistent) row.
        try store.attachTask(machine: "raspcorse", pid: 200, taskID: 99_999)
        try store.acquireLock(machine: "raspcorse", pid: 300, now: instant)

        // task_id pointing at an already-closed row: its status must survive.
        let done = try store.begin(action: "backup", machine: "raspcorse")
        try store.finish(id: done, status: .success, output: "done")
        try store.attachTask(machine: "raspcorse", pid: 300, taskID: done)
        try store.acquireLock(machine: "raspcorse", pid: 400, now: instant)
        XCTAssertEqual(try store.task(id: done)?.status, .success)
        XCTAssertEqual(try store.currentLock(machine: "raspcorse")?.pid, 400)
    }

    /// After a takeover, an `attachTask` still in flight from the old holder must not
    /// rewrite the new holder's lock: the (machine, pid) scope makes it a no-op.
    func testAttachTaskAfterTakeoverIsANoOp() throws {
        let store = try HistoryStore(path: dbPath, isProcessAlive: dead)
        try store.acquireLock(machine: "raspcorse", pid: 111, now: instant)
        try store.acquireLock(machine: "raspcorse", pid: 222, now: instant)

        try store.attachTask(machine: "raspcorse", pid: 111, taskID: 42)
        let lock = try XCTUnwrap(store.currentLock(machine: "raspcorse"))
        XCTAssertEqual(lock.pid, 222)
        XCTAssertNil(lock.taskID, "the old holder must not decorate the new holder's lock")
    }

    /// A lock acquired "in the future" (clock stepped back) would otherwise never age
    /// past the TTL: a negative age counts as stale, not as an eternal lock.
    func testFutureAcquiredAtIsStaleNotEternal() throws {
        let store = try HistoryStore(path: dbPath, isProcessAlive: alive)
        try store.acquireLock(machine: "raspcorse", pid: 111, now: instant.addingTimeInterval(3600))
        try store.acquireLock(machine: "raspcorse", pid: 222, now: instant)
        XCTAssertEqual(try store.currentLock(machine: "raspcorse")?.pid, 222)
    }

    // MARK: - Corrupt lock rows

    /// A lock whose timestamp no longer parses must not be an impasse: the reclaim
    /// paths treat it as stale (or the machine would refuse mutations forever), while
    /// the pure read keeps the corruption-is-an-error doctrine.
    func testCorruptLockTimestampIsReclaimedOnAcquire() throws {
        let store = try HistoryStore(path: dbPath, isProcessAlive: alive)
        let orphan = try store.begin(action: "backup", machine: "raspcorse")
        try store.acquireLock(machine: "raspcorse", pid: 111, now: instant)
        try store.attachTask(machine: "raspcorse", pid: 111, taskID: orphan)
        try rawExec("UPDATE locks SET acquired_at = 'garbage';")

        XCTAssertThrowsError(try store.currentLock(machine: "raspcorse"),
                             "the pure read must still surface corruption")

        try store.acquireLock(machine: "raspcorse", pid: 222, now: instant)
        XCTAssertEqual(try store.currentLock(machine: "raspcorse")?.pid, 222)
        let closed = try XCTUnwrap(store.task(id: orphan))
        XCTAssertEqual(closed.status, .interrupted)
        XCTAssertTrue(closed.output.contains("corrupt"), closed.output)
    }

    func testUnlockRemovesACorruptLockRow() throws {
        let store = try HistoryStore(path: dbPath, isProcessAlive: alive)
        let orphan = try store.begin(action: "backup", machine: "raspcorse")
        try store.acquireLock(machine: "raspcorse", pid: 111, now: instant)
        try store.attachTask(machine: "raspcorse", pid: 111, taskID: orphan)
        try rawExec("UPDATE locks SET acquired_at = 'garbage';")

        XCTAssertEqual(try store.unlock(machine: "raspcorse", now: instant),
                       .releasedCorrupt(orphanClosed: true))
        XCTAssertNil(try store.currentLock(machine: "raspcorse"))
        XCTAssertEqual(try store.task(id: orphan)?.status, .interrupted)
    }

    /// A release scoped by `acquiredAt` frees only the caller's own acquisition: after
    /// this same (machine, pid) reacquired its expired lock, the overrun action's late
    /// release must leave the reacquired lock untouched.
    func testScopedReleaseDoesNotFreeASamePidReacquiredLock() throws {
        let store = try HistoryStore(path: dbPath, isProcessAlive: alive)
        try store.acquireLock(machine: "raspcorse", pid: 111, now: instant)
        let reacquired = instant.addingTimeInterval(HistoryStore.lockTTL + 60)
        try store.acquireLock(machine: "raspcorse", pid: 111, now: reacquired)

        try store.releaseLock(machine: "raspcorse", pid: 111, acquiredAt: instant)
        XCTAssertEqual(try store.currentLock(machine: "raspcorse")?.acquiredAt, reacquired,
                       "the stale acquisition's release must not free the reacquired lock")

        try store.releaseLock(machine: "raspcorse", pid: 111, acquiredAt: reacquired)
        XCTAssertNil(try store.currentLock(machine: "raspcorse"))
    }

    // MARK: - Production probe

    /// The default probe is what production runs and no other test exercises: this
    /// process is alive, degenerate pids are dead by fiat (kill(0,0) would probe our
    /// own process group), and a really-exited child reads as gone.
    func testDefaultProcessProbe() throws {
        XCTAssertTrue(HistoryStore.defaultProcessProbe(getpid()))
        XCTAssertFalse(HistoryStore.defaultProcessProbe(0))
        XCTAssertFalse(HistoryStore.defaultProcessProbe(-1))

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        XCTAssertFalse(HistoryStore.defaultProcessProbe(child.processIdentifier))
    }

    // MARK: - unlock

    func testUnlockRefusesALiveInTTLHolder() throws {
        let store = try HistoryStore(path: dbPath, isProcessAlive: alive)
        try store.acquireLock(machine: "raspcorse", pid: 111, now: instant)

        XCTAssertThrowsError(try store.unlock(machine: "raspcorse",
                                              now: instant.addingTimeInterval(60))) { error in
            XCTAssertTrue("\(error)".contains("held by pid 111"), "\(error)")
            XCTAssertTrue("\(error)".contains("since 2025-08-23T10:40:00Z"), "\(error)")
        }
        XCTAssertEqual(try store.currentLock(machine: "raspcorse")?.pid, 111)
    }

    func testUnlockReleasesAStaleLockAndClosesItsOrphan() throws {
        let store = try HistoryStore(path: dbPath, isProcessAlive: dead)
        let orphan = try store.begin(action: "backup", machine: "raspcorse")
        try store.acquireLock(machine: "raspcorse", pid: 111, now: instant)
        try store.attachTask(machine: "raspcorse", pid: 111, taskID: orphan)

        let outcome = try store.unlock(machine: "raspcorse", now: instant.addingTimeInterval(60))
        guard case .released(let holder, let orphanClosed) = outcome else {
            return XCTFail("expected .released, got \(outcome)")
        }
        XCTAssertEqual(holder.pid, 111)
        XCTAssertTrue(orphanClosed, "a running orphan was really closed: the outcome must say so")
        XCTAssertNil(try store.currentLock(machine: "raspcorse"))
        XCTAssertEqual(try store.task(id: orphan)?.status, .interrupted)
    }

    /// The outcome must not claim a closure that never happened: a stale lock whose task
    /// was already closed releases with `orphanClosed: false` — and the closed verdict
    /// survives untouched.
    func testUnlockOnAnAlreadyClosedTaskReportsNoOrphanClosure() throws {
        let store = try HistoryStore(path: dbPath, isProcessAlive: dead)
        let id = try store.begin(action: "backup", machine: "raspcorse")
        try store.finish(id: id, status: .success, output: "done")
        try store.acquireLock(machine: "raspcorse", pid: 111, now: instant)
        try store.attachTask(machine: "raspcorse", pid: 111, taskID: id)

        let outcome = try store.unlock(machine: "raspcorse", now: instant.addingTimeInterval(60))
        guard case .released(_, let orphanClosed) = outcome else {
            return XCTFail("expected .released, got \(outcome)")
        }
        XCTAssertFalse(orphanClosed, "an already-closed task is not an orphan closure")
        XCTAssertEqual(try store.task(id: id)?.status, .success)
        XCTAssertNil(try store.currentLock(machine: "raspcorse"))
    }

    func testUnlockWithoutALockIsNothingToDo() throws {
        let store = try HistoryStore(path: dbPath, isProcessAlive: alive)
        XCTAssertEqual(try store.unlock(machine: "raspcorse"), .nothingToUnlock)
    }

    // MARK: - Schema

    /// The whole lock semantic fits schema v1: no migration, no new column, no bump.
    func testLockLifecycleLeavesSchemaV1Intact() throws {
        let store = try HistoryStore(path: dbPath, isProcessAlive: dead)
        try store.acquireLock(machine: "raspcorse", pid: 111)
        try store.acquireLock(machine: "raspcorse", pid: 222)
        try store.releaseLock(machine: "raspcorse", pid: 222)
        _ = try store.unlock(machine: "raspcorse")

        XCTAssertEqual(try rawQuery("PRAGMA user_version;"), ["4"])
        XCTAssertEqual(try rawQuery("SELECT name FROM pragma_table_info('locks') ORDER BY cid;"),
                       ["machine", "pid", "acquired_at", "task_id"])
    }
}
