import Foundation

extension HomeportManager {
    /// Complete uninstall: final backup first, then unit + app + config + data are
    /// removed. /var/backups/homeport deliberately survives (and the Mac keeps its
    /// own copies).
    public func remove(on machine: Machine) throws {
        try journaled("remove", on: machine) { try performRemove(on: machine) }
    }

    private func performRemove(on machine: Machine) throws {
        let data = try dataDir(on: machine)
        report("Taking a final backup of \(machine.name)…")
        try backup(on: machine)

        report("Removing Homeport from \(machine.name)…")
        let script = """
        set -euo pipefail
        systemctl disable --now homeport || true
        rm -f /etc/systemd/system/homeport.service
        systemctl daemon-reload
        rm -rf /opt/homeport \(RemotePaths.config) \(data)
        """
        let result = try ssh.run(on: machine.ssh, script, sudo: true)
        guard result.succeeded else {
            throw HPMError("removal on \(machine.name) failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        report("Homeport removed from \(machine.name). Backups kept in \(RemotePaths.backups) and \(localBackupDir(for: machine.name)).")
    }
}
