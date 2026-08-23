import XCTest
@testable import HomePortKit

final class RestoreTests: XCTestCase {
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

    func testRestoreExplicitArchive() throws {
        try manager.restore(on: machine, archive: "/tmp/some-backup.tar.gz")

        XCTAssertTrue(mock.calls.contains {
            $0.executable == "/usr/bin/scp" && $0.line.contains("/tmp/some-backup.tar.gz")
                && $0.line.contains("raspcorse:/tmp/hpm-restore.tar.gz")
        })
        let script = mock.calls.compactMap(\.stdin).first { $0.contains("systemctl stop homeport") }
        XCTAssertNotNil(script)
        XCTAssertTrue(script!.contains("etc-homeport"))
        XCTAssertTrue(script!.contains("var-lib-homeport"))
        XCTAssertTrue(script!.contains("chown -R homeport:homeport"))
        XCTAssertTrue(script!.contains("systemctl start homeport"))
        XCTAssertTrue(mock.calls.contains { $0.line.contains("healthz") })
    }

    func testRestoreNilPicksLatestLocal() throws {
        let dir = backupRoot + "/raspcorse"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: "\(dir)/homeport_raspcorse_v0.3.0_20260801-000000.tar.gz", contents: Data())
        FileManager.default.createFile(atPath: "\(dir)/homeport_raspcorse_v0.4.0_20260820-120000.tar.gz", contents: Data())

        try manager.restore(on: machine, archive: nil)
        XCTAssertTrue(mock.calls.contains { $0.line.contains("homeport_raspcorse_v0.4.0_20260820-120000.tar.gz") })
    }

    func testRestoreNilWithoutBackupsThrows() {
        XCTAssertThrowsError(try manager.restore(on: machine, archive: nil)) { error in
            XCTAssertTrue("\(error)".contains(self.backupRoot + "/raspcorse"))
        }
    }

    func testRestoreScriptFailureThrows() {
        mock.stub(matching: "systemctl stop homeport", exitCode: 1, stderr: "corrupt archive")
        XCTAssertThrowsError(try manager.restore(on: machine, archive: "/tmp/a.tar.gz")) { error in
            XCTAssertTrue("\(error)".contains("corrupt archive"))
        }
    }
}
