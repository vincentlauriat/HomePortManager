import Foundation

extension HomeportManager {
    /// Complete uninstall: final backup first, then unit + app + config + data are
    /// removed. /var/backups/homeport deliberately survives (and the Mac keeps its
    /// own copies).
    public func remove(on machine: Machine) throws {
        report("Taking a final backup of \(machine.name)…")
        try backup(on: machine)

        report("Removing Homeport from \(machine.name)…")
        let script = """
        set -euo pipefail
        systemctl disable --now homeport || true
        rm -f /etc/systemd/system/homeport.service
        systemctl daemon-reload
        rm -rf /opt/homeport \(RemotePaths.config) \(RemotePaths.data)
        """
        let result = try ssh.run(on: machine.ssh, script, sudo: true)
        guard result.succeeded else {
            throw HPMError("removal on \(machine.name) failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        report("Homeport removed from \(machine.name). Backups kept in \(RemotePaths.backups) and \(localBackupDir(for: machine.name)).")
    }
}
