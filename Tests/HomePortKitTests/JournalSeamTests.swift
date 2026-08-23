import XCTest
import SQLite3
@testable import HomePortKit

/// Covers the `journaled` seam through real manager actions: the behaviours the
/// frontends and story 1.3 take for granted.
final class JournalSeamTests: XCTestCase {
    private let machine = Machine(name: "raspcorse", ssh: "raspcorse")
    private var root: String!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        root = NSTemporaryDirectory() + "hpm-journal-\(UUID().uuidString)"
        dbPath = root + "/hpm.db"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
        super.tearDown()
    }

    func testSuccessfulActionJournalsOneClosedEntry() throws {
        let mock = MockProcessRunner()
        let manager = makeTestManager(mock: mock, historyPath: dbPath)
        _ = try manager.backup(on: machine)

        let entries = try XCTUnwrap(manager.history).tasks()
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.action, "backup")
        XCTAssertEqual(entry.machine, "raspcorse")
        XCTAssertEqual(entry.status, .success)
        XCTAssertNotNil(entry.finishedAt)
        // Output is the report stream, captured in the kit even when the frontend
        // passes `{ _ in }` (the default of makeTestManager).
        XCTAssertTrue(entry.output.contains("Creating backup on raspcorse"), entry.output)
    }

    func testFailedActionJournalsFailureAndRethrows() throws {
        let mock = MockProcessRunner()
        mock.stub(matching: "systemctl restart", exitCode: 1, stderr: "boom")
        let manager = makeTestManager(mock: mock, historyPath: dbPath)

        XCTAssertThrowsError(try manager.restart(on: machine)) { error in
            XCTAssertTrue("\(error)".contains("boom"), "original error must be rethrown: \(error)")
        }

        let entry = try XCTUnwrap(try XCTUnwrap(manager.history).tasks().first)
        XCTAssertEqual(entry.action, "restart")
        XCTAssertEqual(entry.status, .failure)
        XCTAssertTrue(entry.output.contains("boom"), "error message must join the output: \(entry.output)")
        XCTAssertTrue(entry.output.contains("Restarting homeport on raspcorse"), entry.output)
    }

    func testComposedUpdateJournalsSingleEntry() throws {
        let mock = MockProcessRunner()
        let cacheDir = NSTemporaryDirectory() + "hpm-cache-\(UUID().uuidString)"
        // Pre-cache the tarball so install() skips the download.
        try FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: cacheDir + "/homeport-v1.0.0.tar.gz", contents: Data())
        defer { try? FileManager.default.removeItem(atPath: cacheDir) }

        let manager = makeTestManager(mock: mock, cacheDir: cacheDir, historyPath: dbPath)
        try manager.update(on: machine, version: "v1.0.0")

        let entries = try XCTUnwrap(manager.history).tasks()
        XCTAssertEqual(entries.map(\.action), ["update"], "nested backup and install must not journal")
        XCTAssertEqual(entries.first?.status, .success)
        // The composed entry still carries the nested actions' narrative.
        let output = try XCTUnwrap(entries.first?.output)
        XCTAssertTrue(output.contains("Creating backup on raspcorse"), output)
        XCTAssertTrue(output.contains("Installing Homeport v1.0.0"), output)
    }

    /// The fragile half of the depth guard: when a *nested* action fails, the journal
    /// must still hold exactly one entry — the composed one, closed as failure — and
    /// never an orphaned nested row.
    func testComposedUpdateFailureJournalsSingleFailureEntry() throws {
        let mock = MockProcessRunner()
        // The nested backup's remote script fails; update rethrows.
        mock.stub(matching: "tar -C", exitCode: 1, stderr: "disk full")
        let manager = makeTestManager(mock: mock, historyPath: dbPath)

        XCTAssertThrowsError(try manager.update(on: machine, version: "v1.0.0"))

        let entries = try XCTUnwrap(manager.history).tasks()
        XCTAssertEqual(entries.map(\.action), ["update"], "a failing nested action must not journal its own entry")
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.status, .failure)
        XCTAssertNotNil(entry.finishedAt, "the composed entry must be closed, not left running")
        XCTAssertTrue(entry.output.contains("disk full"), entry.output)
    }

    func testManagerWithoutHistoryCreatesNoDatabase() throws {
        let mock = MockProcessRunner()
        let manager = makeTestManager(mock: mock, historyPath: nil)
        _ = try manager.backup(on: machine)
        XCTAssertNil(manager.history)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbPath))
    }

    func testConsecutiveActionsJournalSeparately() throws {
        let mock = MockProcessRunner()
        let manager = makeTestManager(mock: mock, historyPath: dbPath)
        _ = try manager.backup(on: machine)
        try manager.restart(on: machine)

        let entries = try XCTUnwrap(manager.history).tasks()
        XCTAssertEqual(entries.map(\.action), ["restart", "backup"])
        // The buffer drains between actions: no cross-contamination of outputs.
        XCTAssertFalse(try XCTUnwrap(entries.first?.output).contains("Creating backup"), entries.first?.output ?? "")
    }

    /// AD-16: pure reads never journal, even on a manager *with* a history — wrapping
    /// `status` in `journaled` would fill the journal at the app's 300 s polling pace.
    func testPureReadsNeverJournal() throws {
        let mock = MockProcessRunner()
        mock.stub(matching: "echo ::", stdout: "v0.4.0\n::\nactive\n::\nOK\n::\n100\n::\n 43%\n")
        mock.stub(matching: "healthz 2>/dev/null", stdout: #"{"status":"ok","version":"0.4.0"}"#)
        let manager = makeTestManager(mock: mock, historyPath: dbPath)

        _ = try manager.status(of: machine)
        _ = try manager.logs(on: machine, lines: 10)
        // The Logs tab's follow is a read like the other two, and a far worse one to
        // journal: it restarts on every tab visit and every Follow toggle.
        _ = try manager.followLogs(on: machine)

        XCTAssertEqual(try XCTUnwrap(manager.history).tasks().count, 0,
                       "reads must leave the journal untouched")
    }

    /// The degradation promise of the seam's `try?`: a journal that breaks *after*
    /// opening (begin fails) must neither abort nor fail the action itself.
    func testJournalWriteFailureDegradesWithoutBlockingAction() throws {
        let mock = MockProcessRunner()
        let manager = makeTestManager(mock: mock, historyPath: dbPath)
        // Sabotage through a second connection: without its table, begin()'s INSERT
        // fails, and the seam has to swallow that and run the body anyway.
        var saboteur: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &saboteur), SQLITE_OK)
        defer { sqlite3_close_v2(saboteur) }
        XCTAssertEqual(sqlite3_exec(saboteur, "DROP TABLE tasks;", nil, nil, nil), SQLITE_OK)

        _ = try manager.backup(on: machine)

        XCTAssertTrue(mock.calls.contains { ($0.stdin ?? "").contains("tar") || $0.line.contains("tar") },
                      "the action itself must have run despite the broken journal")
    }

    // MARK: - Lock in the seam (story 1.3)

    /// The invariant every locking action shares: the lock is taken for the action and
    /// gone afterwards — including when the body throws.
    func testLockingActionAcquiresAndReleasesEvenOnFailure() throws {
        let mock = MockProcessRunner()
        let manager = makeTestManager(mock: mock, historyPath: dbPath)
        _ = try manager.backup(on: machine)
        XCTAssertNil(try XCTUnwrap(manager.history).currentLock(machine: "raspcorse"))

        mock.stub(matching: "systemctl restart", exitCode: 1, stderr: "boom")
        XCTAssertThrowsError(try manager.restart(on: machine))
        XCTAssertNil(try XCTUnwrap(manager.history).currentLock(machine: "raspcorse"),
                     "a failing body must still release the lock")
        XCTAssertEqual(try XCTUnwrap(manager.history).tasks().map(\.status), [.failure, .success])
    }

    /// A refused attempt has neither beginning nor end: nothing lands in the journal,
    /// and the holder's lock survives untouched.
    func testContentionIsRefusedBeforeAnyJournalWrite() throws {
        let mock = MockProcessRunner()
        let manager = makeTestManager(mock: mock, historyPath: dbPath)
        // Another "process" (a second store, this process's live PID) holds the machine.
        let holder = try HistoryStore(path: dbPath)
        try holder.acquireLock(machine: "raspcorse", pid: getpid())

        XCTAssertThrowsError(try manager.backup(on: machine)) { error in
            XCTAssertTrue("\(error)".contains("held by pid \(getpid())"), "\(error)")
        }
        XCTAssertEqual(try holder.tasks().count, 0, "a refused action must not journal")
        XCTAssertEqual(try holder.currentLock(machine: "raspcorse")?.pid, getpid())
        XCTAssertFalse(mock.calls.contains { ($0.stdin ?? "").contains("tar") },
                       "the refused body must not have run")
    }

    /// One composition, one lock: if the nested backup and install re-acquired, they
    /// would collide with update's own lock and fail — success is the proof.
    func testComposedUpdateTakesASingleLock() throws {
        let mock = MockProcessRunner()
        let cacheDir = NSTemporaryDirectory() + "hpm-cache-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: cacheDir + "/homeport-v1.0.0.tar.gz", contents: Data())
        defer { try? FileManager.default.removeItem(atPath: cacheDir) }

        let manager = makeTestManager(mock: mock, cacheDir: cacheDir, historyPath: dbPath)
        try manager.update(on: machine, version: "v1.0.0")
        XCTAssertNil(try XCTUnwrap(manager.history).currentLock(machine: "raspcorse"))
    }

    /// AD-16 under contention: doctor and config-pull run while another process holds
    /// the machine, and leave its lock exactly as they found it.
    func testNonLockingActionsRunDespiteAForeignLock() throws {
        let mock = MockProcessRunner()
        mock.stub(matching: "echo ::", stdout: "v0.4.0\n::\nactive\n::\nOK\n::\n100\n::\n 43%\n")
        mock.stub(matching: "healthz 2>/dev/null", stdout: #"{"status":"ok","version":"0.4.0"}"#)
        let manager = makeTestManager(mock: mock, historyPath: dbPath)
        let holder = try HistoryStore(path: dbPath)
        let acquiredAt = Date(timeIntervalSince1970: 1_755_945_600)
        try holder.acquireLock(machine: "raspcorse", pid: getpid(), now: acquiredAt)

        _ = try manager.doctor(on: machine)
        _ = try manager.configPull(from: machine)
        _ = try manager.prereqs(on: machine, fix: false)
        // Reading a journal must not wait on whoever holds the machine: an operator
        // watching the logs of a running backup is the case this exists for.
        _ = try manager.followLogs(on: machine)

        let lock = try XCTUnwrap(holder.currentLock(machine: "raspcorse"))
        XCTAssertEqual(lock.pid, getpid())
        XCTAssertEqual(lock.acquiredAt, acquiredAt, "readers must not touch the lock")
    }

    /// Pins the `locking: true` classification of every mutating site: dropping any one
    /// of them to `locking: false` turns this red. The refusal fires before the body,
    /// so no stub needs to make the actions runnable.
    func testEveryLockingActionIsRefusedUnderAForeignLock() throws {
        let mock = MockProcessRunner()
        let manager = makeTestManager(mock: mock, historyPath: dbPath)
        let holder = try HistoryStore(path: dbPath)
        try holder.acquireLock(machine: "raspcorse", pid: getpid())

        let attempts: [(name: String, run: () throws -> Void)] = [
            ("backup", { _ = try manager.backup(on: self.machine) }),
            ("restart", { try manager.restart(on: self.machine) }),
            ("install", { try manager.install(on: self.machine, version: "v1.0.0") }),
            ("update", { try manager.update(on: self.machine, version: "v1.0.0") }),
            ("restore", { try manager.restore(on: self.machine, archive: "/tmp/a.tar.gz") }),
            ("remove", { try manager.remove(on: self.machine) }),
            ("config-push", { try manager.configPush(to: self.machine, file: nil) }),
            ("prereqs --fix", { _ = try manager.prereqs(on: self.machine, fix: true) }),
        ]
        for attempt in attempts {
            XCTAssertThrowsError(try attempt.run(), attempt.name) { error in
                XCTAssertTrue("\(error)".contains("held by pid"), "\(attempt.name): \(error)")
            }
        }
        XCTAssertEqual(try holder.tasks().count, 0, "refused attempts must not journal")
        XCTAssertTrue(mock.calls.isEmpty, "no refused body may have run: \(mock.calls)")
    }

    /// Pins the seam's `attachTask` call: while the body runs, the lock row must carry
    /// the journal entry's id — without it, a crash mid-mutation leaves a `running` row
    /// that no takeover can ever close.
    func testSeamAttachesTheJournalEntryToTheLock() throws {
        let mock = MockProcessRunner()
        let observer = try HistoryStore(path: dbPath)
        var observed: HistoryStore.LockInfo?
        let manager = makeTestManager(mock: mock, historyPath: dbPath, report: { line in
            if line.contains("Creating backup"), observed == nil {
                observed = try? observer.currentLock(machine: "raspcorse")
            }
        })
        _ = try manager.backup(on: machine)

        let lock = try XCTUnwrap(observed, "the lock must exist while the body runs")
        XCTAssertEqual(lock.pid, getpid())
        let entry = try XCTUnwrap(observer.tasks().first)
        XCTAssertEqual(lock.taskID, entry.id,
                       "the lock must point at the entry a takeover would close")
    }

    /// `prereqs` locks only when it mutates: the pure check passes a held machine, the
    /// fixing variant is refused like any other mutation.
    func testPrereqsLocksOnlyWhenFixing() throws {
        let mock = MockProcessRunner()
        let manager = makeTestManager(mock: mock, historyPath: dbPath)
        let holder = try HistoryStore(path: dbPath)
        try holder.acquireLock(machine: "raspcorse", pid: getpid())

        _ = try manager.prereqs(on: machine, fix: false)
        XCTAssertThrowsError(try manager.prereqs(on: machine, fix: true)) { error in
            XCTAssertTrue("\(error)".contains("held by pid"), "\(error)")
        }
    }

    /// The doctrine's other half: a *live* base whose lock machinery breaks mid-flight
    /// (here: the `locks` table dropped underneath) must degrade exactly like a broken
    /// journal — warn and run unlocked, never refuse. Only contention refuses.
    func testLockInfrastructureFailureDegradesWithoutBlockingAction() throws {
        let mock = MockProcessRunner()
        let manager = makeTestManager(mock: mock, historyPath: dbPath)
        var saboteur: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &saboteur), SQLITE_OK)
        defer { sqlite3_close_v2(saboteur) }
        XCTAssertEqual(sqlite3_exec(saboteur, "DROP TABLE locks;", nil, nil, nil), SQLITE_OK)

        _ = try manager.backup(on: machine)

        XCTAssertTrue(mock.calls.contains { ($0.stdin ?? "").contains("tar") || $0.line.contains("tar") },
                      "the action itself must have run despite the broken lock machinery")
        // The journal is intact and still adopts the action.
        XCTAssertEqual(try XCTUnwrap(manager.history).tasks().map(\.status), [.success])
    }

    /// The takeover-during-the-body scenario the sticky `interrupted` exists for: a
    /// second process reclaims the (expired) lock and closes the task while the original
    /// holder still runs. The holder's late `finish` throws in the store — and the seam
    /// must degrade that into its warning: the action still returns its result, and the
    /// `interrupted` verdict survives.
    func testLateFinishAfterTakeoverDegradesAndKeepsInterrupted() throws {
        let mock = MockProcessRunner()
        let path = try XCTUnwrap(dbPath)
        var tookOver = false
        let manager = makeTestManager(mock: mock, historyPath: path, report: { line in
            guard line.contains("Creating backup"), !tookOver else { return }
            tookOver = true
            // A taker whose probe sees every holder dead reclaims mid-body.
            let taker = try? HistoryStore(path: path, isProcessAlive: { _ in false })
            try? taker?.acquireLock(machine: "raspcorse", pid: 99_999)
        })

        _ = try manager.backup(on: machine)

        XCTAssertTrue(tookOver, "the takeover must have happened during the body")
        let observer = try HistoryStore(path: dbPath)
        let entry = try XCTUnwrap(observer.tasks().first)
        XCTAssertEqual(entry.status, .interrupted,
                       "the holder's late finish must not rewrite the takeover's verdict")
        // The taker's lock is someone else's: the holder's scoped release left it alone.
        XCTAssertEqual(try observer.currentLock(machine: "raspcorse")?.pid, 99_999)
    }

    /// The 1.2 doctrine extended to the lock: no usable base means no lock and no
    /// refusal — the action just runs.
    func testHistoryNilMeansNoLockAndNoRefusal() throws {
        let mock = MockProcessRunner()
        let manager = makeTestManager(mock: mock, historyPath: nil)
        _ = try manager.backup(on: machine)
        _ = try manager.backup(on: machine)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbPath))
    }

    /// Pins journal adoption on every wrapped action the other tests don't drive:
    /// dropping a `journaled` wrapper — or mistyping a stable identifier such as
    /// `config-pull` — must turn a test red, not ship silently.
    func testEveryOtherWrappedActionJournalsItsStableIdentifier() throws {
        let mock = MockProcessRunner()
        // doctor needs a healthy status probe; install a cached tarball; config a seed.
        mock.stub(matching: "echo ::", stdout: "v0.4.0\n::\nactive\n::\nOK\n::\n100\n::\n 43%\n")
        mock.stub(matching: "healthz 2>/dev/null", stdout: #"{"status":"ok","version":"0.4.0"}"#)
        let cacheDir = NSTemporaryDirectory() + "hpm-cache-\(UUID().uuidString)"
        let configRoot = NSTemporaryDirectory() + "hpm-configs-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: cacheDir + "/homeport-v0.4.0.tar.gz", contents: Data("tgz".utf8))
        try FileManager.default.createDirectory(atPath: configRoot + "/raspcorse", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: configRoot + "/raspcorse/services.yaml",
                                       contents: Data("services: []\n".utf8))
        defer {
            try? FileManager.default.removeItem(atPath: cacheDir)
            try? FileManager.default.removeItem(atPath: configRoot)
        }

        let manager = makeTestManager(mock: mock, cacheDir: cacheDir, configRoot: configRoot,
                                      historyPath: dbPath)
        try manager.restore(on: machine, archive: "/tmp/a.tar.gz")
        try manager.install(on: machine, version: "v0.4.0")
        try manager.remove(on: machine)
        _ = try manager.doctor(on: machine)
        _ = try manager.prereqs(on: machine, fix: false)
        _ = try manager.configPull(from: machine)
        try manager.configPush(to: machine, file: "services.yaml")

        let entries = try XCTUnwrap(manager.history).tasks()
        XCTAssertEqual(entries.map(\.action),
                       ["config-push", "config-pull", "prereqs", "doctor", "remove", "install", "restore"],
                       "one entry per user action, newest first, under its stable identifier — nested backup (remove) and prereqs (doctor) stay silent")
        XCTAssertTrue(entries.allSatisfy { $0.status == .success && $0.machine == "raspcorse" }, "\(entries)")
    }
}
