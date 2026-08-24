import XCTest
@testable import HomePortKit

final class ProcessRunnerTests: XCTestCase {
    func testMockRecordsCallsAndReturnsStub() throws {
        let mock = MockProcessRunner()
        mock.stub(matching: "hello", exitCode: 3, stdout: "out", stderr: "err")

        let hit = try mock.run("/usr/bin/ssh", ["host", "hello world"])
        XCTAssertEqual(hit, CommandResult(exitCode: 3, stdout: "out", stderr: "err"))

        let miss = try mock.run("/usr/bin/ssh", ["host", "other"])
        XCTAssertEqual(miss.exitCode, 0)
        XCTAssertEqual(mock.calls.count, 2)
        XCTAssertEqual(mock.calls[0].arguments, ["host", "hello world"])
    }

    func testLastStubWins() throws {
        let mock = MockProcessRunner()
        mock.stub(matching: "cmd", exitCode: 1)
        mock.stub(matching: "cmd", exitCode: 2)
        XCTAssertEqual(try mock.run("/bin/sh", ["cmd"]).exitCode, 2)
    }

    func testDefaultRunnerEcho() throws {
        let result = try DefaultProcessRunner().run("/bin/echo", ["hi"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "hi\n")
        XCTAssertTrue(result.succeeded)
    }

    func testDefaultRunnerFailure() throws {
        let result = try DefaultProcessRunner().run("/usr/bin/false", [])
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertFalse(result.succeeded)
    }

    func testDefaultRunnerStdin() throws {
        let result = try DefaultProcessRunner().run("/bin/cat", [], stdin: "ping")
        XCTAssertEqual(result.stdout, "ping")
    }

    /// Both output pipes have to drain concurrently. Read one after the other, a child that
    /// fills stderr's ~64KiB buffer blocks on its own write, never reaches EOF on stdout, and
    /// hangs the caller for good.
    ///
    /// Note the failure mode: before the fix these two tests do not fail, they *hang* — which
    /// is precisely the bug, and why neither could have been caught by a passing suite.
    func testDefaultRunnerDrainsBothPipesWhenStderrOverflowsItsBuffer() throws {
        // 256KiB on stderr, four times the buffer, with stdout written only afterwards.
        let script = "head -c 262144 /dev/zero | tr '\\0' 'x' >&2; echo done"
        let result = try DefaultProcessRunner().run("/bin/sh", ["-c", script], stdin: nil)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "done\n")
        XCTAssertEqual(result.stderr.count, 262_144)
    }

    /// The same hazard on the input side: the child fills an output buffer before it has
    /// finished reading stdin, so a write that precedes the drains never returns.
    func testDefaultRunnerDrainsWhileWritingALargeStdin() throws {
        let input = String(repeating: "y", count: 200_000)
        // Echoes its input back on stderr while stdout also fills.
        let script = "cat >&2; head -c 100000 /dev/zero | tr '\\0' 'z'"
        let result = try DefaultProcessRunner().run("/bin/sh", ["-c", script], stdin: input)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr.count, 200_000)
        XCTAssertEqual(result.stdout.count, 100_000)
    }

    // MARK: - Streaming

    func testDefaultRunnerStreamsLinesInOrder() async throws {
        let stream = try DefaultProcessRunner().stream("/bin/sh", ["-c", "echo alpha; echo bravo"])
        var received: [String] = []
        for await line in stream.lines { received.append(line) }
        XCTAssertEqual(received, ["alpha", "bravo"])
        XCTAssertNil(stream.failure)
    }

    /// A child that ends mid-line still gets its last line delivered — once, and whole.
    func testDefaultRunnerStreamFlushesAnUnterminatedLastLine() async throws {
        let stream = try DefaultProcessRunner().stream("/bin/sh", ["-c", #"printf "alpha\nbra""#])
        var received: [String] = []
        for await line in stream.lines { received.append(line) }
        XCTAssertEqual(received, ["alpha", "bra"])
    }

    func testDefaultRunnerStreamFeedsStdin() async throws {
        let stream = try DefaultProcessRunner().stream("/bin/cat", [], stdin: "one\ntwo\n")
        var received: [String] = []
        for await line in stream.lines { received.append(line) }
        XCTAssertEqual(received, ["one", "two"])
    }

    /// A stream cannot throw its transport failure the way `run` does — by the time the
    /// command dies the call has long returned. The verdict waits in `failure` instead.
    func testDefaultRunnerStreamReportsANonZeroExit() async throws {
        let stream = try DefaultProcessRunner().stream("/bin/sh", ["-c", "echo boom >&2; exit 3"])
        for await _ in stream.lines {}
        let failure = try XCTUnwrap(stream.failure)
        XCTAssertTrue(failure.contains("3"), failure)
        XCTAssertTrue(failure.contains("boom"), failure)
    }

    /// The failure mode this whole path exists to prevent: an ssh outliving the tab that
    /// started it. `stop()` ends the stream *and* the child.
    func testDefaultRunnerStreamStopTerminatesTheChild() async throws {
        let stream = try DefaultProcessRunner().stream(
            "/bin/sh", ["-c", "echo $$; while :; do sleep 0.1; done"])
        var iterator = stream.lines.makeAsyncIterator()
        let firstLine = await iterator.next()
        let announced = try XCTUnwrap(firstLine)
        let pid = try XCTUnwrap(pid_t(announced.trimmingCharacters(in: .whitespaces)))

        stream.stop()
        // The consumer is released rather than left waiting on a child that is going away.
        while await iterator.next() != nil {}
        // Stopping on purpose is not a failure, whatever exit code a killed child leaves.
        XCTAssertNil(stream.failure)

        var alive = true
        for _ in 0..<200 {
            if kill(pid, 0) != 0 {
                alive = false
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(alive, "the child process outlived stop()")
    }

    func testDefaultRunnerStreamStopIsIdempotent() async throws {
        let stream = try DefaultProcessRunner().stream("/bin/sh", ["-c", "while :; do sleep 0.1; done"])
        stream.stop()
        stream.stop()
        for await _ in stream.lines {}
    }

    /// A pipe read stops wherever the kernel decided, which can be inside a multi-byte
    /// character. Decoding each chunk on its own would cut that character in half and put a
    /// replacement glyph in the middle of a line — French journald messages are full of them.
    func testDefaultRunnerStreamRebuildsMultiByteCharactersSplitAcrossReads() async throws {
        // Two writes, a pause between them, and the pause falls inside the é (0xC3 0xA9).
        let script = #"printf 'connexion \303'; sleep 0.3; printf '\251tablie\n'"#
        let stream = try DefaultProcessRunner().stream("/bin/sh", ["-c", script])
        var received: [String] = []
        for await line in stream.lines { received.append(line) }
        XCTAssertEqual(received, ["connexion établie"])
    }

    /// The net under every caller's discipline: a stream simply dropped — the consuming task
    /// cancelled, the owning view released — must still take the child down. This is the
    /// failure the whole design exists to prevent, and only `onTermination`/`deinit` cover it.
    func testDefaultRunnerStreamReleasedWithoutStopStillKillsTheChild() async throws {
        func startAndDrop() async throws -> pid_t {
            let stream = try DefaultProcessRunner().stream(
                "/bin/sh", ["-c", "echo $$; while :; do sleep 0.1; done"])
            var iterator = stream.lines.makeAsyncIterator()
            let first = await iterator.next()
            let announced = try XCTUnwrap(first)
            return try XCTUnwrap(pid_t(announced.trimmingCharacters(in: .whitespaces)))
            // No stop() anywhere: the stream and its iterator go out of scope here.
        }
        let pid = try await startAndDrop()

        var alive = true
        for _ in 0..<200 {
            if kill(pid, 0) != 0 {
                alive = false
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(alive, "the child process outlived the release of its stream")
    }

    func testDefaultRunnerStreamThrowsOnAMissingExecutable() {
        XCTAssertThrowsError(try DefaultProcessRunner().stream("/nonexistent/binary", []))
    }
}
