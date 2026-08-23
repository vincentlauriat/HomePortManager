import Foundation

extension HomeportManager {
    /// Reads the version marker written by install/update; "unknown" when absent.
    public func installedVersion(on machine: Machine) throws -> String {
        let result = try ssh.run(on: machine.ssh,
                                 "cat \(RemotePaths.versionMarker) 2>/dev/null || echo unknown")
        let version = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? "unknown" : version
    }

    public func localBackupDir(for machineName: String) -> String {
        "\(backupRoot)/\(machineName)"
    }

    /// Effective data directory: a systemd drop-in may override HOMEPORT_DATA_DIR
    /// (raspcorse keeps its data on an SSD, not in /var/lib/homeport).
    public func dataDir(on machine: Machine) throws -> String {
        let result = try ssh.run(on: machine.ssh,
                                 "systemctl show \(RemotePaths.unit) -p Environment 2>/dev/null")
        let overrides = result.stdout
            .replacingOccurrences(of: "Environment=", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\n" })
            .filter { $0.hasPrefix("HOMEPORT_DATA_DIR=") }
            .map { String($0.dropFirst("HOMEPORT_DATA_DIR=".count)) }
        return overrides.last ?? RemotePaths.data
    }

    /// Archives /etc/homeport + /var/lib/homeport on the machine (keep 3 there),
    /// pulls the archive to the Mac (keep 10 here). Returns the local archive path.
    @discardableResult
    public func backup(on machine: Machine) throws -> String {
        try journaled("backup", on: machine, locking: true) { try performBackup(on: machine) }
    }

    private func performBackup(on machine: Machine) throws -> String {
        let version = try installedVersion(on: machine)
        let data = try dataDir(on: machine)
        let stamp = Self.timestampFormatter.string(from: Date())
        let archive = "homeport_\(machine.name)_\(version)_\(stamp).tar.gz"
        let remoteArchive = "\(RemotePaths.backups)/\(archive)"

        report("Creating backup on \(machine.name) (\(version))…")
        let script = """
        set -euo pipefail
        staging=$(mktemp -d)
        trap 'rm -rf "$staging"' EXIT
        mkdir -p \(RemotePaths.backups)
        cp -a \(RemotePaths.config) "$staging/etc-homeport"
        mkdir -p "$staging/var-lib-homeport"
        if command -v sqlite3 >/dev/null 2>&1; then
          find \(data) -maxdepth 1 -type f \\( -name '*.db' -o -name '*.sqlite*' \\) | while read -r f; do
            sqlite3 "$f" ".backup '$staging/var-lib-homeport/$(basename "$f")'"
          done
          find \(data) -mindepth 1 -maxdepth 1 ! \\( -type f \\( -name '*.db' -o -name '*.sqlite*' \\) \\) -exec cp -a {} "$staging/var-lib-homeport/" \\;
        else
          cp -a \(data)/. "$staging/var-lib-homeport/"
        fi
        tar -C "$staging" -czf \(remoteArchive) .
        ls -1t \(RemotePaths.backups)/homeport_\(machine.name)_*.tar.gz | tail -n +4 | xargs -r rm --
        """
        let result = try ssh.run(on: machine.ssh, script, sudo: true)
        guard result.succeeded else {
            throw HPMError("backup on \(machine.name) failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        let localDir = localBackupDir(for: machine.name)
        try FileManager.default.createDirectory(atPath: localDir, withIntermediateDirectories: true)
        let localPath = "\(localDir)/\(archive)"
        report("Pulling backup to \(localPath)…")
        try ssh.pull(from: machine.ssh, remotePath: remoteArchive, to: localPath)
        try rotateLocalBackups(for: machine.name)
        return localPath
    }

    /// Newest archive on the Mac for this machine (timestamped names sort chronologically).
    public func latestLocalBackup(for machineName: String) -> String? {
        let dir = localBackupDir(for: machineName)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return files
            .filter { $0.hasPrefix("homeport_\(machineName)_") && $0.hasSuffix(".tar.gz") }
            .sorted { backupSortKey($0) > backupSortKey($1) }
            .first
            .map { "\(dir)/\($0)" }
    }

    func rotateLocalBackups(for machineName: String, keep: Int = 10) throws {
        let dir = localBackupDir(for: machineName)
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasPrefix("homeport_\(machineName)_") && $0.hasSuffix(".tar.gz") }
            .sorted { backupSortKey($0) > backupSortKey($1) }
        for file in files.dropFirst(keep) {
            try FileManager.default.removeItem(atPath: "\(dir)/\(file)")
        }
    }

    /// Sort archives by their trailing timestamp so version strings of different
    /// lengths cannot skew the ordering.
    private func backupSortKey(_ filename: String) -> String {
        let stem = filename.replacingOccurrences(of: ".tar.gz", with: "")
        return String(stem.split(separator: "_").last ?? Substring(stem))
    }

    static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
