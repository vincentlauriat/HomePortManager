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
}
