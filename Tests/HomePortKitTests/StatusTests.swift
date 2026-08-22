import XCTest
@testable import HomePortKit

final class StatusTests: XCTestCase {
    private var mock: MockProcessRunner!
    private var backupRoot: String!
    private var manager: HomeportManager!
    private let machine = Machine(name: "raspcorse", ssh: "raspcorse")

    override func setUp() {
        super.setUp()
        mock = MockProcessRunner()
        backupRoot = NSTemporaryDirectory() + "hpm-backups-\(UUID().uuidString)"
        manager = makeTestManager(mock: mock, backupRoot: backupRoot)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: backupRoot)
        super.tearDown()
    }

    func testHealthyMachine() throws {
        mock.stub(matching: "healthz", stdout: "v0.4.0\n::\nactive\n::\nOK\n")
        let status = try manager.status(of: machine)
        XCTAssertEqual(status, MachineStatus(name: "raspcorse", reachable: true,
                                             installedVersion: "v0.4.0", serviceActive: true,
                                             healthzOK: true, lastBackup: nil))
    }

    func testDegradedMachine() throws {
        mock.stub(matching: "healthz", stdout: "\n::\ninactive\n::\nFAIL\n")
        let status = try manager.status(of: machine)
        XCTAssertEqual(status.installedVersion, "unknown")
        XCTAssertFalse(status.serviceActive)
        XCTAssertFalse(status.healthzOK)
        XCTAssertTrue(status.reachable)
    }

    func testUnreachableMachineDoesNotThrow() throws {
        mock.stub(matching: "healthz", exitCode: 255, stderr: "timeout")
        let status = try manager.status(of: machine)
        XCTAssertEqual(status, MachineStatus(name: "raspcorse", reachable: false,
                                             installedVersion: "-", serviceActive: false,
                                             healthzOK: false, lastBackup: nil))
    }

    func testLastBackupFromLocalDir() throws {
        let dir = backupRoot + "/raspcorse"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: "\(dir)/homeport_raspcorse_v0.4.0_20260820-120000.tar.gz", contents: Data())
        mock.stub(matching: "healthz", stdout: "v0.4.0\n::\nactive\n::\nOK\n")
        XCTAssertEqual(try manager.status(of: machine).lastBackup,
                       "homeport_raspcorse_v0.4.0_20260820-120000.tar.gz")
    }

    func testSingleSSHCall() throws {
        mock.stub(matching: "healthz", stdout: "v0.4.0\n::\nactive\n::\nOK\n")
        _ = try manager.status(of: machine)
        XCTAssertEqual(mock.calls.count, 1, "status must use one combined ssh call")
    }
}
