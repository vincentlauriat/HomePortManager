import XCTest
@testable import HomePortKit

final class InstallTests: XCTestCase {
    private var mock: MockProcessRunner!
    private var cacheDir: String!
    private var manager: HomeportManager!
    private let machine = Machine(name: "raspcorse", ssh: "raspcorse")

    override func setUp() {
        super.setUp()
        mock = MockProcessRunner()
        cacheDir = NSTemporaryDirectory() + "hpm-cache-\(UUID().uuidString)"
        manager = makeTestManager(mock: mock, cacheDir: cacheDir)
        // Pre-populate the tarball cache so no curl download is attempted.
        try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: cacheDir + "/homeport-v0.4.0.tar.gz", contents: Data("tgz".utf8))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: cacheDir)
        super.tearDown()
    }

    func testInstallPipeline() throws {
        try manager.install(on: machine, version: "v0.4.0")

        // Tarball pushed.
        XCTAssertTrue(mock.calls.contains {
            $0.executable == "/usr/bin/scp" && $0.line.contains("raspcorse:/tmp/hpm-homeport.tar.gz")
        })
        // Remote script runs install.sh and writes the version marker.
        let script = mock.calls.compactMap(\.stdin).first { $0.contains("install.sh") }
        XCTAssertNotNil(script)
        XCTAssertTrue(script!.contains("--strip-components=1"))
        XCTAssertTrue(script!.contains("./deploy/install.sh"))
        XCTAssertTrue(script!.contains("echo v0.4.0 > \(RemotePaths.versionMarker)"))
        // Health checked over ssh.
        XCTAssertTrue(mock.calls.contains { $0.line.contains("localhost:80/healthz") })
    }

    func testInstallResolvesLatestWhenVersionNil() throws {
        mock.stub(matching: "/releases", stdout: #"[{"tag_name":"v0.4.0","published_at":null}]"#)
        try manager.install(on: machine, version: nil)
        XCTAssertTrue(mock.calls.compactMap(\.stdin).contains { $0.contains("echo v0.4.0 >") })
    }

    func testInstallScriptFailureThrows() {
        mock.stub(matching: "install.sh", exitCode: 1, stderr: "python3-venv missing")
        XCTAssertThrowsError(try manager.install(on: machine, version: "v0.4.0")) { error in
            XCTAssertTrue("\(error)".contains("python3-venv missing"))
        }
    }

    func testFailingHealthzThrows() {
        mock.stub(matching: "healthz", exitCode: 7)
        XCTAssertThrowsError(try manager.checkHealth(on: machine, attempts: 3, delaySeconds: 0))
        XCTAssertEqual(mock.calls.filter { $0.line.contains("healthz") }.count, 3)
    }

    func testUpdateBacksUpBeforeInstalling() throws {
        mock.stub(matching: ".hpm-version", stdout: "v0.3.0\n")
        try manager.update(on: machine, version: "v0.4.0")

        let stdins = mock.calls.compactMap(\.stdin)
        let backupIndex = stdins.firstIndex { $0.contains("tar -C") && $0.contains("etc-homeport") }
        let installIndex = stdins.firstIndex { $0.contains("install.sh") }
        XCTAssertNotNil(backupIndex, "update must back up first")
        XCTAssertNotNil(installIndex)
        XCTAssertLessThan(backupIndex!, installIndex!, "backup must run before install.sh")
    }
}
