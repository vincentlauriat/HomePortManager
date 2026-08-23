import XCTest
@testable import HomePortKit

final class ServiceTests: XCTestCase {
    private var mock: MockProcessRunner!
    private var manager: HomeportManager!
    private let machine = Machine(name: "raspcorse", ssh: "raspcorse")

    override func setUp() {
        super.setUp()
        mock = MockProcessRunner()
        manager = makeTestManager(mock: mock)
    }

    func testLogsRunsJournalctlWithSudo() throws {
        mock.stub(matching: "journalctl", stdout: "line1\nline2\n")
        let output = try manager.logs(on: machine, lines: 30)
        XCTAssertEqual(output, "line1\nline2\n")
        let call = mock.calls.first { ($0.stdin ?? "").contains("journalctl") }
        XCTAssertNotNil(call, "journalctl must go through sudo bash -s")
        XCTAssertTrue(call!.stdin!.contains("-n 30"))
        XCTAssertTrue(call!.stdin!.contains("--no-pager"))
    }

    func testLogsFailureThrows() {
        mock.stub(matching: "journalctl", exitCode: 1, stderr: "no unit")
        XCTAssertThrowsError(try manager.logs(on: machine))
    }

    func testRestartThenHealthz() throws {
        try manager.restart(on: machine)
        let stdins = mock.calls.compactMap(\.stdin)
        XCTAssertTrue(stdins.contains { $0.contains("systemctl restart homeport.service") })
        XCTAssertTrue(mock.calls.contains { $0.line.contains("healthz") })
    }

    func testRestartFailureThrows() {
        mock.stub(matching: "systemctl restart", exitCode: 1, stderr: "unit masked")
        XCTAssertThrowsError(try manager.restart(on: machine)) { error in
            XCTAssertTrue("\(error)".contains("unit masked"))
        }
    }
}
