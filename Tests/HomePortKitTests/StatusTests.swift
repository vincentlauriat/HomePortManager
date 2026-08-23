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

    func testHealthyMachineFullParse() throws {
        mock.stub(matching: "healthz", stdout: "v0.5.0\n::\nactive\n::\nOK\n::\n93784\n::\n 43%\n")
        let status = try manager.status(of: machine)
        XCTAssertTrue(status.reachable)
        XCTAssertEqual(status.installedVersion, "v0.5.0")
        XCTAssertTrue(status.serviceActive)
        XCTAssertTrue(status.healthzOK)
        XCTAssertEqual(status.uptimeSeconds, 93784)
        XCTAssertEqual(status.diskUsedPercent, 43)
        XCTAssertNotNil(status.sshLatencyMs)
    }

    func testDegradedMachine() throws {
        mock.stub(matching: "healthz", stdout: "\n::\ninactive\n::\nFAIL\n::\n\n::\n\n")
        let status = try manager.status(of: machine)
        XCTAssertEqual(status.installedVersion, "unknown")
        XCTAssertFalse(status.serviceActive)
        XCTAssertFalse(status.healthzOK)
        XCTAssertNil(status.uptimeSeconds)
        XCTAssertNil(status.diskUsedPercent)
        XCTAssertTrue(status.reachable)
    }

    func testUnreachableMachineDoesNotThrow() throws {
        mock.stub(matching: "healthz", exitCode: 255, stderr: "timeout")
        let status = try manager.status(of: machine)
        XCTAssertFalse(status.reachable)
        XCTAssertEqual(status.installedVersion, "-")
        XCTAssertNil(status.sshLatencyMs)
    }

    func testLastBackupFromLocalDir() throws {
        let dir = backupRoot + "/raspcorse"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: "\(dir)/homeport_raspcorse_v0.4.0_20260820-120000.tar.gz", contents: Data())
        mock.stub(matching: "healthz", stdout: "v0.5.0\n::\nactive\n::\nOK\n::\n1\n::\n1%\n")
        XCTAssertEqual(try manager.status(of: machine).lastBackup,
                       "homeport_raspcorse_v0.4.0_20260820-120000.tar.gz")
    }

    func testSingleSSHCall() throws {
        mock.stub(matching: "healthz", stdout: "v0.5.0\n::\nactive\n::\nOK\n::\n1\n::\n1%\n")
        _ = try manager.status(of: machine)
        XCTAssertEqual(mock.calls.count, 1, "status must use one combined ssh call")
        // The combined command resolves the data dir remotely (drop-in aware).
        XCTAssertTrue(mock.calls[0].line.contains("HOMEPORT_DATA_DIR="))
    }

    func testFormatUptime() {
        XCTAssertEqual(formatUptime(nil), "-")
        XCTAssertEqual(formatUptime(47), "47s")
        XCTAssertEqual(formatUptime(125), "2m")
        XCTAssertEqual(formatUptime(7500), "2h 05m")
        XCTAssertEqual(formatUptime(93784), "1d 2h")
    }
}
