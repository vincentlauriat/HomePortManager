import Foundation

extension HomeportManager {
    /// Restores config + data from a backup archive (nil → newest local archive for this
    /// machine). Also works across machines: pass another machine's archive to migrate.
    public func restore(on machine: Machine, archive: String?) throws {
        let archivePath: String
        if let archive {
            archivePath = expandPath(archive)
        } else if let latest = latestLocalBackup(for: machine.name) {
            archivePath = latest
        } else {
            throw HPMError("no local backup found for '\(machine.name)' in \(localBackupDir(for: machine.name)) — run: hpm backup \(machine.name)")
        }

        report("Restoring \((archivePath as NSString).lastPathComponent) on \(machine.name)…")
        try ssh.push(archivePath, to: machine.ssh, remotePath: "/tmp/hpm-restore.tar.gz")

        let script = """
        set -euo pipefail
        systemctl stop homeport || true
        staging=$(mktemp -d)
        trap 'rm -rf "$staging" /tmp/hpm-restore.tar.gz' EXIT
        tar -xzf /tmp/hpm-restore.tar.gz -C "$staging"
        test -d "$staging/etc-homeport" && test -d "$staging/var-lib-homeport"
        rm -rf \(RemotePaths.config) \(RemotePaths.data)
        cp -a "$staging/etc-homeport" \(RemotePaths.config)
        cp -a "$staging/var-lib-homeport" \(RemotePaths.data)
        chown -R homeport:homeport \(RemotePaths.data)
        systemctl start homeport
        """
        let result = try ssh.run(on: machine.ssh, script, sudo: true)
        guard result.succeeded else {
            throw HPMError("restore on \(machine.name) failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        try checkHealth(on: machine)
        report("Restore complete on \(machine.name).")
    }
}
