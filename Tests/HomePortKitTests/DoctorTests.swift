import XCTest
@testable import HomePortKit

final class DoctorTests: XCTestCase {
    private var mock: MockProcessRunner!
    private var manager: HomeportManager!
    private let machine = Machine(name: "raspcorse", ssh: "raspcorse")

    override func setUp() {
        super.setUp()
        mock = MockProcessRunner()
        manager = makeTestManager(mock: mock)
    }

    private func stubHealthyStatus(version: String = "v0.5.0", disk: Int = 43) {
        mock.stub(matching: "echo ::", stdout: "\(version)\n::\nactive\n::\nOK\n::\n100\n::\n \(disk)%\n")
        mock.stub(matching: "healthz 2>/dev/null", stdout: #"{"status":"ok","version":"0.5.0"}"#)
    }

    func testAllGreen() throws {
        stubHealthyStatus()
        let checks = try manager.doctor(on: machine)
        XCTAssertEqual(checks.map(\.name), ["systemd", "python3-venv", "rsync", "sudo",
                                            "service", "healthz", "version", "disk"])
        XCTAssertTrue(checks.allSatisfy(\.ok), "\(checks.filter { !$0.ok })")
    }

    func testStaleCodeDetected() throws {
        mock.stub(matching: "echo ::", stdout: "v0.6.0\n::\nactive\n::\nOK\n::\n100\n::\n 43%\n")
        mock.stub(matching: "healthz 2>/dev/null", stdout: #"{"status":"ok","version":"0.5.0"}"#)
        let checks = try manager.doctor(on: machine)
        let version = checks.first { $0.name == "version" }
        XCTAssertEqual(version?.ok, false)
        XCTAssertTrue(version!.detail.contains("stale"))
    }

    func testDiskFullDetected() throws {
        stubHealthyStatus(disk: 95)
        let disk = try manager.doctor(on: machine).first { $0.name == "disk" }
        XCTAssertEqual(disk?.ok, false)
        XCTAssertTrue(disk!.detail.contains("95%"))
    }

    func testInactiveServiceDetected() throws {
        mock.stub(matching: "echo ::", stdout: "v0.5.0\n::\ninactive\n::\nFAIL\n::\n\n::\n\n")
        mock.stub(matching: "healthz 2>/dev/null", stdout: "")
        let checks = try manager.doctor(on: machine)
        XCTAssertEqual(checks.first { $0.name == "service" }?.ok, false)
        XCTAssertEqual(checks.first { $0.name == "healthz" }?.ok, false)
        // No JSON body → no version check; no disk value → no disk check.
        XCTAssertFalse(checks.contains { $0.name == "version" })
        XCTAssertFalse(checks.contains { $0.name == "disk" })
    }

    func testNoConfigCheckWithoutLocalCopies() throws {
        stubHealthyStatus()
        XCTAssertFalse(try manager.doctor(on: machine).contains { $0.name == "config" })
    }
}
