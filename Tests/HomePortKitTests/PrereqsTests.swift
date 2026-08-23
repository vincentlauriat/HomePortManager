import XCTest
@testable import HomePortKit

/// Shared helper to build a HomeportManager wired to mocks.
func makeTestManager(mock: MockProcessRunner,
                     backupRoot: String = NSTemporaryDirectory() + "hpm-backups-\(UUID().uuidString)",
                     cacheDir: String = NSTemporaryDirectory() + "hpm-cache-\(UUID().uuidString)",
                     configRoot: String = NSTemporaryDirectory() + "hpm-configs-\(UUID().uuidString)",
                     report: @escaping Reporter = { _ in }) -> HomeportManager {
    HomeportManager(
        ssh: SSHClient(runner: mock),
        releases: ReleaseService(runner: mock, cacheDir: cacheDir),
        backupRoot: backupRoot,
        configRoot: configRoot,
        runner: mock,
        report: report
    )
}

final class PrereqsTests: XCTestCase {
    private let machine = Machine(name: "raspcorse", ssh: "raspcorse")

    func testAllChecksPass() throws {
        let mock = MockProcessRunner()
        let checks = try makeTestManager(mock: mock).prereqs(on: machine, fix: false)
        XCTAssertEqual(checks.count, 4)
        XCTAssertTrue(checks.allSatisfy(\.ok))
        XCTAssertEqual(checks.map(\.name), ["systemd", "python3-venv", "rsync", "sudo"])
    }

    func testFailingCheckReported() throws {
        let mock = MockProcessRunner()
        mock.stub(matching: "rsync", exitCode: 1)
        let checks = try makeTestManager(mock: mock).prereqs(on: machine, fix: false)
        XCTAssertEqual(checks.first { $0.name == "rsync" }?.ok, false)
        XCTAssertEqual(mock.calls.filter { $0.line.contains("apt-get") }.count, 0)
    }

    func testFixInstallsAndRechecks() throws {
        let mock = MockProcessRunner()
        // venv check fails until apt-get has been called.
        mock.stub(matching: "python3 -m venv", exitCode: 1)
        var aptRan = false
        let manager = makeTestManager(mock: mock)
        // After apt-get runs, make the venv check pass again.
        mock.stub(matching: "apt-get", result: CommandResult(exitCode: 0, stdout: "", stderr: ""))
        // We can't flip a stub mid-run with this mock, so verify behaviour instead:
        let checks = try manager.prereqs(on: machine, fix: true)
        aptRan = mock.calls.contains { ($0.stdin ?? $0.line).contains("apt-get install -y python3-venv rsync") }
        XCTAssertTrue(aptRan)
        // The re-check ran (two venv probes in the call list).
        let venvProbes = mock.calls.filter { $0.line.contains("python3 -m venv") }
        XCTAssertEqual(venvProbes.count, 2)
        XCTAssertEqual(checks.count, 4)
    }

    func testSudoNotFixable() throws {
        let mock = MockProcessRunner()
        mock.stub(matching: "sudo -n true", exitCode: 1)
        let checks = try makeTestManager(mock: mock).prereqs(on: machine, fix: true)
        XCTAssertEqual(checks.first { $0.name == "sudo" }?.ok, false)
        XCTAssertFalse(mock.calls.contains { ($0.stdin ?? "").contains("apt-get") })
    }
}
