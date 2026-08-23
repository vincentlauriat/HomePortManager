import Foundation

/// Agentless remote access: everything goes through the system ssh/scp binaries,
/// so the user's SSH config and Tailscale network apply unchanged.
public struct SSHClient {
    private let runner: ProcessRunner
    private static let batchOptions = ["-o", "BatchMode=yes"]

    public init(runner: ProcessRunner) {
        self.runner = runner
    }

    /// Runs a command on the host. Throws only on ssh transport failure (exit 255);
    /// other exit codes are the remote command's business and are returned as-is.
    /// With `sudo: true` the command is fed to `sudo bash -s` via stdin, which avoids
    /// all shell-quoting pitfalls for multi-line scripts.
    @discardableResult
    public func run(on host: String, _ command: String, sudo: Bool = false, stdin: String? = nil) throws -> CommandResult {
        let result: CommandResult
        if sudo {
            result = try runner.run("/usr/bin/ssh", Self.batchOptions + [host, "sudo bash -s"],
                                    stdin: stdin ?? command)
        } else {
            result = try runner.run("/usr/bin/ssh", Self.batchOptions + [host, command], stdin: stdin)
        }
        if result.exitCode == 255 {
            throw HPMError("ssh to '\(host)' failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result
    }

    /// Keepalives, on the streaming path only. A one-shot `run` finishes in seconds and its
    /// failure mode is an exit code; a follow lives for hours, and a link that dies silently
    /// — a tailnet drop, a Pi that goes to sleep — never makes the local ssh exit on its own.
    /// Without these, the consumer waits forever on a stream that will never yield or end,
    /// and shows a live-looking follow that is in fact frozen. `run` keeps its own options
    /// untouched: every existing action and the CLI go through it.
    private static let streamOptions = [
        "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=3",
        "-o", "ConnectTimeout=10",
    ]

    /// Same command and same `sudo bash -s` stdin path as `run`, plus the keepalives above —
    /// but the output arrives line by line for as long as the remote command lives, instead
    /// of once at the end. Throws only if the local ssh could not be started at all; a
    /// transport failure that happens later surfaces as `ProcessOutputStream.failure` when
    /// the stream ends.
    public func stream(on host: String, _ command: String, sudo: Bool = false) throws -> ProcessOutputStream {
        let options = Self.batchOptions + Self.streamOptions
        if sudo {
            return try runner.stream("/usr/bin/ssh", options + [host, "sudo bash -s"],
                                     stdin: command)
        }
        return try runner.stream("/usr/bin/ssh", options + [host, command], stdin: nil)
    }

    public func push(_ localPath: String, to host: String, remotePath: String) throws {
        let result = try runner.run("/usr/bin/scp", ["-q"] + Self.batchOptions + [localPath, "\(host):\(remotePath)"], stdin: nil)
        guard result.succeeded else {
            throw HPMError("scp to '\(host)' failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    public func pull(from host: String, remotePath: String, to localPath: String) throws {
        let result = try runner.run("/usr/bin/scp", ["-q"] + Self.batchOptions + ["\(host):\(remotePath)", localPath], stdin: nil)
        guard result.succeeded else {
            throw HPMError("scp from '\(host)' failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}
