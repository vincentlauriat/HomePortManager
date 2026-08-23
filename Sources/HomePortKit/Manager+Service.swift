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

    /// The same journal, followed instead of sampled: `journalctl -n N -f` serves the last N
    /// lines and then keeps going, so one command fills the history *and* the follow. Running
    /// a one-shot first and a follow after would deliver those N lines twice.
    ///
    /// Reading a journal is a read: no lock, no journal entry of its own.
    public func followLogs(on machine: Machine, lines: Int = LogDefaults.tail) throws -> ProcessOutputStream {
        // A zero or negative tail is not something journalctl accepts: it would refuse the
        // argument and the follow would never start.
        try ssh.stream(on: machine.ssh,
                       "journalctl -u \(RemotePaths.unit) -n \(max(1, lines)) -f --no-pager",
                       sudo: true)
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
