import XCTest
@testable import HomePortKit

/// The follow seam: the exact remote command the app runs, and the consumption of the stream
/// it hands back. The `Process` half of `DefaultProcessRunner.stream` is not exercisable
/// here — the mock replaces it — so this pins everything above it.
final class LogFollowTests: XCTestCase {
    private var mock: MockProcessRunner!
    private var manager: HomeportManager!
    private let machine = Machine(name: "raspcorse", ssh: "pi@raspcorse")

    override func setUp() {
        super.setUp()
        mock = MockProcessRunner()
        manager = makeTestManager(mock: mock)
    }

    func testFollowLogsIssuesTheFollowingJournalctl() throws {
        _ = try manager.followLogs(on: machine, lines: 200)
        let call = try XCTUnwrap(mock.streamCalls.first)
        XCTAssertEqual(call.executable, "/usr/bin/ssh")
        XCTAssertTrue(call.arguments.contains("BatchMode=yes"))
        XCTAssertTrue(call.arguments.contains("pi@raspcorse"))
        // sudo goes through `bash -s` fed by stdin, exactly like the one-shot `logs`.
        XCTAssertTrue(call.arguments.contains("sudo bash -s"))
        let script = try XCTUnwrap(call.stdin)
        XCTAssertEqual(script, "journalctl -u homeport.service -n 200 -f --no-pager")
    }

    func testFollowLogsDefaultsToTheDocumentedTail() throws {
        _ = try manager.followLogs(on: machine)
        let script = try XCTUnwrap(mock.streamCalls.first?.stdin)
        XCTAssertTrue(script.contains("-n \(LogDefaults.tail)"))
    }

    /// The two reads do *not* share a default tail, and that is deliberate: `logs` keeps the
    /// 50 lines `hpm logs` has always served, the follow serves the tab's 200. Pinned here so
    /// that "aligning the defaults" is recognised as a CLI behaviour change, not a cleanup.
    func testTheOneShotKeepsItsOwnFiftyLineDefault() throws {
        mock.stub(matching: "journalctl", stdout: "")
        _ = try manager.logs(on: machine)
        _ = try manager.followLogs(on: machine)
        let oneShot = try XCTUnwrap(mock.calls.first { ($0.stdin ?? "").contains("journalctl") }?.stdin)
        XCTAssertTrue(oneShot.contains("-n 50"), oneShot)
        let follow = try XCTUnwrap(mock.streamCalls.first?.stdin)
        XCTAssertTrue(follow.contains("-n 200"), follow)
    }

    /// A tail journalctl would refuse never reaches it.
    func testFollowClampsANonPositiveTail() throws {
        _ = try manager.followLogs(on: machine, lines: 0)
        let script = try XCTUnwrap(mock.streamCalls.first?.stdin)
        XCTAssertTrue(script.contains("-n 1"), script)
    }

    /// A follow lives for hours: without keepalives a silently dropped link never makes the
    /// local ssh exit, and the tab shows a frozen follow that never reports itself stopped.
    /// `run` must stay untouched — every existing action and the CLI go through it.
    func testFollowAsksSSHToNoticeADeadLink() throws {
        _ = try manager.followLogs(on: machine)
        let stream = try XCTUnwrap(mock.streamCalls.first)
        XCTAssertTrue(stream.arguments.contains("ServerAliveInterval=15"), "\(stream.arguments)")
        XCTAssertTrue(stream.arguments.contains("ServerAliveCountMax=3"), "\(stream.arguments)")
        XCTAssertTrue(stream.arguments.contains("ConnectTimeout=10"), "\(stream.arguments)")

        // A fresh runner, so the one-shot is the only call recorded on it.
        let plain = MockProcessRunner()
        plain.stub(matching: "journalctl", stdout: "")
        _ = try makeTestManager(mock: plain).logs(on: machine)
        let oneShot = try XCTUnwrap(plain.calls.first)
        XCTAssertFalse(oneShot.arguments.contains("ServerAliveInterval=15"), "\(oneShot.arguments)")
    }

    /// `followLogs` always asks for sudo, so nothing else covers the plain branch: it must
    /// pass the command as an argument and leave stdin alone.
    func testStreamWithoutSudoPassesTheCommandInline() throws {
        _ = try SSHClient(runner: mock).stream(on: "pi@raspcorse", "true")
        let call = try XCTUnwrap(mock.streamCalls.first)
        XCTAssertTrue(call.arguments.contains("true"))
        XCTAssertFalse(call.arguments.contains("sudo bash -s"))
        XCTAssertNil(call.stdin)
    }

    /// Position, not just membership: `ssh` takes its options *before* the host, reads the
    /// first non-option argument as the host, and hands everything after it to the remote
    /// shell. Regrouping this array — appending the keepalives after the host, say — still
    /// contains every token the assertions above look for, while producing a follow that can
    /// never connect. The one-shot is protected from that exact mistake by
    /// `SSHClientTests.testRunBuildsSSHCommand`; this is its counterpart for the stream.
    func testStreamArgumentsAreOrderedAsSSHExpects() throws {
        let expectedOptions = ["-o", "BatchMode=yes",
                               "-o", "ServerAliveInterval=15",
                               "-o", "ServerAliveCountMax=3",
                               "-o", "ConnectTimeout=10"]

        _ = try manager.followLogs(on: machine)
        XCTAssertEqual(mock.streamCalls.first?.executable, "/usr/bin/ssh")
        XCTAssertEqual(mock.streamCalls.first?.arguments,
                       expectedOptions + ["pi@raspcorse", "sudo bash -s"])

        let plain = MockProcessRunner()
        _ = try SSHClient(runner: plain).stream(on: "pi@raspcorse", "true")
        XCTAssertEqual(plain.streamCalls.first?.arguments,
                       expectedOptions + ["pi@raspcorse", "true"])
    }

    /// The one-shot and the follow must stay the same command in two modes: same unit, same
    /// pager setting, same sudo path — only `-f` and the tail differ.
    func testFollowAndOneShotShareTheirShape() throws {
        mock.stub(matching: "journalctl", stdout: "")
        _ = try manager.logs(on: machine, lines: 200)
        _ = try manager.followLogs(on: machine, lines: 200)
        let oneShot = try XCTUnwrap(mock.calls.first { ($0.stdin ?? "").contains("journalctl") }?.stdin)
        let follow = try XCTUnwrap(mock.streamCalls.first?.stdin)
        XCTAssertEqual(follow, oneShot.replacingOccurrences(of: "--no-pager", with: "-f --no-pager"))
    }

    func testStreamedLinesAreConsumedInOrderUntilTheStreamEnds() async throws {
        mock.stubStream(matching: "journalctl", lines: ["alpha", "ERROR: bravo", "charlie"])
        let stream = try manager.followLogs(on: machine)
        var received: [String] = []
        for await line in stream.lines { received.append(line) }
        XCTAssertEqual(received, ["alpha", "ERROR: bravo", "charlie"])
        XCTAssertNil(stream.failure)
    }

    func testStreamCarriesTheFailureVerdictOnceItEnds() async throws {
        mock.stubStream(matching: "journalctl", lines: ["alpha"],
                        failure: "exit 255: ssh: connect to host raspcorse port 22: No route to host")
        let stream = try manager.followLogs(on: machine)
        var received: [String] = []
        for await line in stream.lines { received.append(line) }
        XCTAssertEqual(received, ["alpha"])
        XCTAssertEqual(stream.failure?.hasPrefix("exit 255"), true)
    }

    func testStopIsIdempotent() throws {
        let stream = try manager.followLogs(on: machine)
        stream.stop()
        stream.stop()
        stream.stop()
        XCTAssertEqual(mock.stopCount, 1)
    }

    /// A runner that only knows how to `run` stays a valid conformer, and says so rather
    /// than silently handing back an empty stream.
    func testRunnersWithoutStreamingRefuseExplicitly() {
        struct RunOnlyRunner: ProcessRunner {
            func run(_ executable: String, _ arguments: [String], stdin: String?) throws -> CommandResult {
                CommandResult(exitCode: 0, stdout: "", stderr: "")
            }
        }
        XCTAssertThrowsError(try SSHClient(runner: RunOnlyRunner()).stream(on: "host", "true"))
    }
}
