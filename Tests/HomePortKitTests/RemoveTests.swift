import XCTest
@testable import HomePortKit

final class RemoveTests: XCTestCase {
    private var mock: MockProcessRunner!
    private var manager: HomeportManager!
    private let machine = Machine(name: "raspcorse", ssh: "raspcorse")

    override func setUp() {
        super.setUp()
        mock = MockProcessRunner()
        manager = makeTestManager(mock: mock)
    }

    func testRemoveBacksUpFirst() throws {
        try manager.remove(on: machine)

        let stdins = mock.calls.compactMap(\.stdin)
        let backupIndex = stdins.firstIndex { $0.contains("tar -C") && $0.contains("etc-homeport") }
        let removeIndex = stdins.firstIndex { $0.contains("rm -rf /opt/homeport") }
        XCTAssertNotNil(backupIndex, "remove must take a final backup")
        XCTAssertNotNil(removeIndex)
        XCTAssertLessThan(backupIndex!, removeIndex!)
    }

    func testRemoveScriptContents() throws {
        try manager.remove(on: machine)
        let script = mock.calls.compactMap(\.stdin).first { $0.contains("rm -rf /opt/homeport") }!
        XCTAssertTrue(script.contains("systemctl disable --now homeport"))
        XCTAssertTrue(script.contains("rm -f /etc/systemd/system/homeport.service"))
        XCTAssertTrue(script.contains("systemctl daemon-reload"))
        XCTAssertTrue(script.contains("/etc/homeport"))
        XCTAssertTrue(script.contains("/var/lib/homeport"))
        XCTAssertFalse(script.contains("rm -rf /var/backups"),
                       "on-machine backups must survive removal")
    }

    func testRemoveScriptFailureThrows() {
        mock.stub(matching: "rm -rf /opt/homeport", exitCode: 1, stderr: "device busy")
        XCTAssertThrowsError(try manager.remove(on: machine)) { error in
            XCTAssertTrue("\(error)".contains("device busy"))
        }
    }
}
