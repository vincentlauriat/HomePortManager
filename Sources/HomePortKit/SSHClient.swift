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
