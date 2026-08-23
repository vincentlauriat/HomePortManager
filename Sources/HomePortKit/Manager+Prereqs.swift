import Foundation

public struct PrereqCheck: Equatable {
    public let name: String
    public let ok: Bool
    public let detail: String
}

/// Orchestrates every Homeport life-cycle operation. Holds no state: each method is a
/// self-contained pipeline that reports progress and throws HPMError on first failure.
public final class HomeportManager {
    public let ssh: SSHClient
    public let releases: ReleaseService
    public let backupRoot: String
    public let configRoot: String
    let runner: ProcessRunner   // for local tools (diff); remote work goes through ssh
    public let report: Reporter

    public init(ssh: SSHClient, releases: ReleaseService,
                backupRoot: String = "~/HomePortBackups",
                configRoot: String = "~/.config/hpm/configs",
                runner: ProcessRunner = DefaultProcessRunner(),
                report: @escaping Reporter = { print($0) }) {
        self.ssh = ssh
        self.releases = releases
        self.backupRoot = expandPath(backupRoot)
        self.configRoot = expandPath(configRoot)
        self.runner = runner
        self.report = report
    }

    public func prereqs(on machine: Machine, fix: Bool) throws -> [PrereqCheck] {
        var checks = try runPrereqProbes(on: machine)

        let fixable = checks.filter { !$0.ok && ($0.name == "python3-venv" || $0.name == "rsync") }
        if fix && !fixable.isEmpty {
            report("Installing missing packages via apt-get…")
            let result = try ssh.run(on: machine.ssh,
                                     "DEBIAN_FRONTEND=noninteractive apt-get install -y python3-venv rsync",
                                     sudo: true)
            guard result.succeeded else {
                throw HPMError("apt-get install failed on \(machine.name): \(result.stderr)")
            }
            checks = try runPrereqProbes(on: machine)
        }
        return checks
    }

    private func runPrereqProbes(on machine: Machine) throws -> [PrereqCheck] {
        let probes: [(name: String, command: String, detail: String)] = [
            ("systemd", "command -v systemctl", "systemctl not found — Homeport requires systemd"),
            ("python3-venv", "python3 -m venv --help >/dev/null", "install with: apt install python3-venv"),
            ("rsync", "command -v rsync", "install with: apt install rsync"),
            ("sudo", "sudo -n true", "passwordless sudo required for the SSH user"),
        ]
        return try probes.map { probe in
            let result = try ssh.run(on: machine.ssh, probe.command)
            return PrereqCheck(name: probe.name, ok: result.succeeded,
                               detail: result.succeeded ? "" : probe.detail)
        }
    }
}
