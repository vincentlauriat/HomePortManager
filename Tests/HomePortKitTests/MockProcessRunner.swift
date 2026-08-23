import Foundation
@testable import HomePortKit

/// Test double: records every call and answers with substring-matched stubs.
final class MockProcessRunner: ProcessRunner {
    struct Call {
        let executable: String
        let arguments: [String]
        let stdin: String?
        var line: String { ([executable] + arguments).joined(separator: " ") }
    }

    private(set) var calls: [Call] = []
    /// The subset of `calls` that asked for a stream — what pins the follow command.
    private(set) var streamCalls: [Call] = []
    /// How many times a handed-out stream was stopped. The follow plumbing's only
    /// observable lifecycle signal, since no real process exists here.
    private(set) var stopCount = 0
    private var stubs: [(match: String, result: CommandResult)] = []
    private var streamStubs: [(match: String, lines: [String], failure: String?)] = []

    func stub(matching substring: String, result: CommandResult) {
        stubs.append((substring, result))
    }

    func stub(matching substring: String, exitCode: Int32 = 0, stdout: String = "", stderr: String = "") {
        stub(matching: substring, result: CommandResult(exitCode: exitCode, stdout: stdout, stderr: stderr))
    }

    /// Scripts a stream: the lines it replays, and the verdict it leaves behind once done.
    func stubStream(matching substring: String, lines: [String], failure: String? = nil) {
        streamStubs.append((substring, lines, failure))
    }

    func run(_ executable: String, _ arguments: [String], stdin: String?) throws -> CommandResult {
        let call = Call(executable: executable, arguments: arguments, stdin: stdin)
        calls.append(call)
        let haystack = call.line + " " + (stdin ?? "")
        for stub in stubs.reversed() where haystack.contains(stub.match) {
            return stub.result
        }
        return CommandResult(exitCode: 0, stdout: "", stderr: "")
    }

    func stream(_ executable: String, _ arguments: [String], stdin: String?) throws -> ProcessOutputStream {
        let call = Call(executable: executable, arguments: arguments, stdin: stdin)
        calls.append(call)
        streamCalls.append(call)
        let haystack = call.line + " " + (stdin ?? "")
        let stub = streamStubs.reversed().first { haystack.contains($0.match) }
        let scripted = stub?.lines ?? []
        let failure = stub?.failure
        let stream = AsyncStream<String> { continuation in
            for line in scripted { continuation.yield(line) }
            continuation.finish()
        }
        return ProcessOutputStream(lines: stream,
                                   failure: { failure },
                                   stop: { [weak self] in self?.stopCount += 1 })
    }
}
