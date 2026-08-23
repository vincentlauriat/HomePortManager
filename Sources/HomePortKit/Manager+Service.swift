import Foundation

extension HomeportManager {
    /// Last N lines of the service journal (sudo: journal access is restricted).
    public func logs(on machine: Machine, lines: Int = 50) throws -> String {
        let result = try ssh.run(on: machine.ssh,
                                 "journalctl -u \(RemotePaths.unit) -n \(lines) --no-pager",
                                 sudo: true)
        guard result.succeeded else {
            throw HPMError("journalctl on \(machine.name) failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result.stdout
    }

    /// Restart the service, then verify healthz.
    public func restart(on machine: Machine) throws {
        try journaled("restart", on: machine, locking: true) {
            report("Restarting homeport on \(machine.name)…")
            let result = try ssh.run(on: machine.ssh, "systemctl restart \(RemotePaths.unit)", sudo: true)
            guard result.succeeded else {
                throw HPMError("restart on \(machine.name) failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            try checkHealth(on: machine)
            report("homeport is back up on \(machine.name).")
        }
    }
}
