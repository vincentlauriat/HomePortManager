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
