import XCTest
@testable import HomePortKit

final class SSHClientTests: XCTestCase {
    private var mock: MockProcessRunner!
    private var ssh: SSHClient!

    override func setUp() {
        super.setUp()
        mock = MockProcessRunner()
        ssh = SSHClient(runner: mock)
    }

    func testRunBuildsSSHCommand() throws {
        _ = try ssh.run(on: "raspcorse", "systemctl is-active homeport")
        XCTAssertEqual(mock.calls.count, 1)
        XCTAssertEqual(mock.calls[0].executable, "/usr/bin/ssh")
        XCTAssertEqual(mock.calls[0].arguments,
                       ["-o", "BatchMode=yes", "raspcorse", "systemctl is-active homeport"])
    }

    func testRunSudoSendsScriptViaStdin() throws {
        _ = try ssh.run(on: "raspcorse", "rm -rf /opt/homeport", sudo: true)
        XCTAssertEqual(mock.calls[0].arguments, ["-o", "BatchMode=yes", "raspcorse", "sudo bash -s"])
        XCTAssertEqual(mock.calls[0].stdin, "rm -rf /opt/homeport")
    }

    func testRunThrowsOnTransportFailure() {
        mock.stub(matching: "unreachable", exitCode: 255, stderr: "Connection timed out")
        XCTAssertThrowsError(try ssh.run(on: "unreachable", "true")) { error in
            XCTAssertTrue("\(error)".contains("unreachable"))
        }
    }

    func testRunReturnsNonTransportFailures() throws {
        mock.stub(matching: "is-active", exitCode: 3, stdout: "inactive\n")
        let result = try ssh.run(on: "raspcorse", "systemctl is-active homeport")
        XCTAssertEqual(result.exitCode, 3)
    }

    func testPushBuildsScp() throws {
        try ssh.push("/tmp/a.tar.gz", to: "raspcorse", remotePath: "/tmp/b.tar.gz")
        XCTAssertEqual(mock.calls[0].executable, "/usr/bin/scp")
        XCTAssertEqual(mock.calls[0].arguments,
                       ["-q", "-o", "BatchMode=yes", "/tmp/a.tar.gz", "raspcorse:/tmp/b.tar.gz"])
    }

    func testPushThrowsOnFailure() {
        mock.stub(matching: "scp", exitCode: 1, stderr: "No such file")
        XCTAssertThrowsError(try ssh.push("/x", to: "h", remotePath: "/y"))
    }

    func testPullBuildsScp() throws {
        try ssh.pull(from: "raspcorse", remotePath: "/var/backups/a.tar.gz", to: "/tmp/a.tar.gz")
        XCTAssertEqual(mock.calls[0].arguments,
                       ["-q", "-o", "BatchMode=yes", "raspcorse:/var/backups/a.tar.gz", "/tmp/a.tar.gz"])
    }
}
