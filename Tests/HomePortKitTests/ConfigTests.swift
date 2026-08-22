import XCTest
@testable import HomePortKit

final class ConfigTests: XCTestCase {
    private var mock: MockProcessRunner!
    private var configRoot: String!
    private var manager: HomeportManager!
    private let machine = Machine(name: "raspcorse", ssh: "raspcorse")

    override func setUp() {
        super.setUp()
        mock = MockProcessRunner()
        configRoot = NSTemporaryDirectory() + "hpm-configs-\(UUID().uuidString)"
        manager = makeTestManager(mock: mock, configRoot: configRoot)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: configRoot)
        super.tearDown()
    }

    private func seedLocalConfig(_ name: String = "services.yaml") throws {
        let dir = configRoot + "/raspcorse"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: "\(dir)/\(name)", contents: Data("services: []\n".utf8))
    }

    func testPullFetchesEtcHomeport() throws {
        try seedLocalConfig()
        let files = try manager.configPull(from: machine)
        XCTAssertTrue(mock.calls.contains {
            $0.executable == "/usr/bin/scp" && $0.line.contains("raspcorse:/etc/homeport/*")
        })
        XCTAssertEqual(files, ["services.yaml"])
    }

    func testDiffReturnsEmptyWhenIdentical() throws {
        try seedLocalConfig()
        XCTAssertEqual(try manager.configDiff(on: machine, file: nil), "")
    }

    func testDiffReturnsUnifiedDiff() throws {
        try seedLocalConfig()
        mock.stub(matching: "diff -u", exitCode: 1, stdout: "--- remote\n+++ local\n+new: line\n")
        let diff = try manager.configDiff(on: machine, file: "services.yaml")
        XCTAssertTrue(diff.contains("+new: line"))
    }

    func testDiffThrowsOnDiffError() throws {
        try seedLocalConfig()
        mock.stub(matching: "diff -u", exitCode: 2, stderr: "No such file")
        XCTAssertThrowsError(try manager.configDiff(on: machine, file: nil))
    }

    func testDiffWithoutLocalCopyThrows() {
        XCTAssertThrowsError(try manager.configDiff(on: machine, file: nil)) { error in
            XCTAssertTrue("\(error)".contains("hpm config pull"))
        }
    }

    func testPushInstallsWithoutRestart() throws {
        try seedLocalConfig()
        try manager.configPush(to: machine, file: "services.yaml")

        XCTAssertTrue(mock.calls.contains {
            $0.executable == "/usr/bin/scp" && $0.line.contains("services.yaml")
                && $0.line.contains("raspcorse:/tmp/")
        })
        let script = mock.calls.compactMap(\.stdin).first { $0.contains("install -m 644") }
        XCTAssertNotNil(script)
        XCTAssertTrue(script!.contains("/etc/homeport/services.yaml"))
        XCTAssertFalse(mock.calls.contains { ($0.stdin ?? $0.line).contains("systemctl") },
                       "Homeport hot-reloads config; push must not restart the service")
    }

    func testPushUnknownFileThrows() throws {
        try seedLocalConfig()
        XCTAssertThrowsError(try manager.configPush(to: machine, file: "ghost.yaml"))
    }
}
