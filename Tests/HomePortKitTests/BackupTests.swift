import XCTest
@testable import HomePortKit

final class BackupTests: XCTestCase {
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

    func testInstalledVersionReadsMarker() throws {
        mock.stub(matching: ".hpm-version", stdout: "v0.4.0\n")
        XCTAssertEqual(try manager.installedVersion(on: machine), "v0.4.0")
    }

    func testInstalledVersionUnknownWhenMissing() throws {
        mock.stub(matching: ".hpm-version", stdout: "unknown\n")
        XCTAssertEqual(try manager.installedVersion(on: machine), "unknown")
    }

    func testBackupNamingAndPipeline() throws {
        mock.stub(matching: ".hpm-version", stdout: "v0.4.0\n")
        let path = try manager.backup(on: machine)

        XCTAssertTrue(path.hasPrefix(backupRoot + "/raspcorse/"))
        let name = (path as NSString).lastPathComponent
        XCTAssertNotNil(name.range(of: #"^homeport_raspcorse_v0\.4\.0_\d{8}-\d{6}\.tar\.gz$"#,
                                   options: .regularExpression), "unexpected name: \(name)")

        let script = mock.calls.compactMap(\.stdin).first { $0.contains("tar -C") }
        XCTAssertNotNil(script, "remote backup script not sent over sudo bash -s")
        XCTAssertTrue(script!.contains("cp -a /etc/homeport"))
        XCTAssertTrue(script!.contains("var-lib-homeport"))
        XCTAssertTrue(script!.contains("tail -n +4"), "remote rotation (keep 3) missing")
        XCTAssertTrue(script!.contains("sqlite3"), "sqlite-aware copy missing")

        // Archive pulled back to the Mac.
        XCTAssertTrue(mock.calls.contains { $0.executable == "/usr/bin/scp" && $0.line.contains(name) })
    }

    func testLocalRotationKeepsTen() throws {
        let dir = backupRoot + "/raspcorse"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for i in 0..<11 {
            let stamp = String(format: "202608%02d-000000", i + 1)
            FileManager.default.createFile(atPath: "\(dir)/homeport_raspcorse_v0.4.0_\(stamp).tar.gz",
                                           contents: Data())
        }
        try manager.rotateLocalBackups(for: "raspcorse")
        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir).sorted()
        XCTAssertEqual(remaining.count, 10)
        XCTAssertFalse(remaining.contains("homeport_raspcorse_v0.4.0_20260801-000000.tar.gz"),
                       "oldest archive should have been rotated out")
    }

    func testLatestLocalBackup() throws {
        let dir = backupRoot + "/raspcorse"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: "\(dir)/homeport_raspcorse_v0.3.0_20260801-000000.tar.gz", contents: Data())
        FileManager.default.createFile(atPath: "\(dir)/homeport_raspcorse_v0.4.0_20260820-120000.tar.gz", contents: Data())
        XCTAssertEqual(manager.latestLocalBackup(for: "raspcorse"),
                       "\(dir)/homeport_raspcorse_v0.4.0_20260820-120000.tar.gz")
        XCTAssertNil(manager.latestLocalBackup(for: "ghost"))
    }

    func testBackupFailureThrows() {
        mock.stub(matching: "tar -C", exitCode: 1, stderr: "disk full")
        XCTAssertThrowsError(try manager.backup(on: machine)) { error in
            XCTAssertTrue("\(error)".contains("disk full"))
        }
    }
}
