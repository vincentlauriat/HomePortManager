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
    private var stubs: [(match: String, result: CommandResult)] = []

    func stub(matching substring: String, result: CommandResult) {
        stubs.append((substring, result))
    }

    func stub(matching substring: String, exitCode: Int32 = 0, stdout: String = "", stderr: String = "") {
        stub(matching: substring, result: CommandResult(exitCode: exitCode, stdout: stdout, stderr: stderr))
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
}
