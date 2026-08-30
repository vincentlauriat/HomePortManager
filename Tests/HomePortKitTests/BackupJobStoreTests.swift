import XCTest
@testable import HomePortKit

final class BackupJobStoreTests: XCTestCase {
    private var root: String!
    private var store: BackupJobStore!

    override func setUp() {
        super.setUp()
        root = NSTemporaryDirectory() + "hpm-jobs-\(UUID().uuidString)"
        store = BackupJobStore(root: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
        super.tearDown()
    }

    func testLoadMissingReturnsNil() throws {
        XCTAssertNil(try store.load(for: "raspcorse"))
    }

    func testSaveThenLoadRoundTrips() throws {
        let job = BackupJob(schedule: "daily", retention: 5)
        try store.save(job, for: "raspcorse")
        XCTAssertEqual(try store.load(for: "raspcorse"), job)
    }

    func testDefaultRetentionIsThree() {
        XCTAssertEqual(BackupJob(schedule: "daily").retention, 3)
    }

    func testJobsAreStoredPerMachine() throws {
        try store.save(BackupJob(schedule: "daily"), for: "raspcorse")
        try store.save(BackupJob(schedule: "*-*-* 03:30:00", retention: 7), for: "raspyellow")

        XCTAssertEqual(try store.load(for: "raspcorse")?.schedule, "daily")
        XCTAssertEqual(try store.load(for: "raspyellow")?.schedule, "*-*-* 03:30:00")
        XCTAssertEqual(try store.load(for: "raspyellow")?.retention, 7)
    }

    func testSaveOverwritesAPreviousDeclaration() throws {
        try store.save(BackupJob(schedule: "daily", retention: 3), for: "raspcorse")
        try store.save(BackupJob(schedule: "weekly", retention: 4), for: "raspcorse")
        XCTAssertEqual(try store.load(for: "raspcorse"), BackupJob(schedule: "weekly", retention: 4))
    }

    func testUnparsableFileThrows() throws {
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try "not: [valid yaml for BackupJob".write(toFile: root + "/raspcorse.yaml", atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.load(for: "raspcorse"))
    }

    /// The store lives under ~/.config/hpm/jobs (F8) — never hpm.db, which only holds
    /// observed state, never declared/desired state.
    func testDefaultRootMatchesConventionAndNeverTouchesHistoryStore() {
        XCTAssertEqual(BackupJobStore.defaultRoot, "~/.config/hpm/jobs")
    }
}
