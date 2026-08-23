import Foundation

extension HomeportManager {
    public func configDir(for machineName: String) -> String {
        "\(configRoot)/\(machineName)"
    }

    /// Config files can be root-only (mqtt.env holds secrets), so a direct scp of
    /// /etc/homeport fails. Stage them with sudo into /tmp, owned by the SSH user,
    /// pull from there, then clean up. Callers must call cleanupRemoteStaging after.
    private static let remoteStaging = "/tmp/hpm-cfg-pull"

    private func stageRemoteConfig(on machine: Machine) throws {
        let result = try ssh.run(on: machine.ssh, """
        set -euo pipefail
        rm -rf \(Self.remoteStaging)
        mkdir -p \(Self.remoteStaging)
        cp -a \(RemotePaths.config)/. \(Self.remoteStaging)/
        chown -R "$SUDO_USER" \(Self.remoteStaging)
        """, sudo: true)
        guard result.succeeded else {
            throw HPMError("cannot stage config on \(machine.name): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    private func cleanupRemoteStaging(on machine: Machine) {
        _ = try? ssh.run(on: machine.ssh, "rm -rf \(Self.remoteStaging)", sudo: true)
    }

    /// Fetches every file from /etc/homeport into the machine's local config dir.
    /// Returns the local filenames.
    @discardableResult
    public func configPull(from machine: Machine) throws -> [String] {
        // Writes on the Mac only (AD-16): journaled, never locked — the machine is read.
        try journaled("config-pull", on: machine, locking: false) { try performConfigPull(from: machine) }
    }

    private func performConfigPull(from machine: Machine) throws -> [String] {
        let dir = configDir(for: machine.name)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        report("Pulling \(RemotePaths.config)/* from \(machine.name)…")
        try stageRemoteConfig(on: machine)
        defer { cleanupRemoteStaging(on: machine) }
        try ssh.pull(from: machine.ssh, remotePath: "\(Self.remoteStaging)/*", to: dir)
        return try FileManager.default.contentsOfDirectory(atPath: dir).sorted()
    }

    /// Unified diff remote → local for one file (or every locally pulled file).
    /// Empty string means nothing to push.
    public func configDiff(on machine: Machine, file: String?) throws -> String {
        let files = try localConfigFiles(for: machine, file: file)

        let tempDir = NSTemporaryDirectory() + "hpm-diff-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        try stageRemoteConfig(on: machine)
        defer { cleanupRemoteStaging(on: machine) }

        var chunks: [String] = []
        for name in files {
            let remoteCopy = "\(tempDir)/\(name)"
            try ssh.pull(from: machine.ssh, remotePath: "\(Self.remoteStaging)/\(name)", to: remoteCopy)
            let localPath = "\(configDir(for: machine.name))/\(name)"
            let result = try runner.run("/usr/bin/diff", ["-u", remoteCopy, localPath])
            switch result.exitCode {
            case 0: continue
            case 1: chunks.append(result.stdout)
            default:
                throw HPMError("diff failed for \(name) on \(machine.name): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        return chunks.joined(separator: "\n")
    }

    /// Pushes local config file(s) into /etc/homeport. No service restart — Homeport
    /// hot-reloads its configuration.
    public func configPush(to machine: Machine, file: String?) throws {
        try journaled("config-push", on: machine, locking: true) { try performConfigPush(to: machine, file: file) }
    }

    private func performConfigPush(to machine: Machine, file: String?) throws {
        let files = try localConfigFiles(for: machine, file: file)
        let stagingDir = "/tmp/hpm-cfg"
        try ssh.run(on: machine.ssh, "mkdir -p \(stagingDir)")
        for name in files {
            report("Pushing \(name) to \(machine.name)…")
            try ssh.push("\(configDir(for: machine.name))/\(name)", to: machine.ssh,
                         remotePath: "\(stagingDir)/\(name)")
            let result = try ssh.run(on: machine.ssh,
                                     "install -m 644 \(stagingDir)/\(name) \(RemotePaths.config)/\(name) && rm -f \(stagingDir)/\(name)",
                                     sudo: true)
            guard result.succeeded else {
                throw HPMError("push of \(name) to \(machine.name) failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        report("Config applied — Homeport reloads it on the next page refresh.")
    }

    private func localConfigFiles(for machine: Machine, file: String?) throws -> [String] {
        let dir = configDir(for: machine.name)
        let all = (try? FileManager.default.contentsOfDirectory(atPath: dir))?.sorted() ?? []
        if let file {
            guard all.contains(file) else {
                throw HPMError("no local copy of '\(file)' in \(dir) — run: hpm config pull \(machine.name)")
            }
            return [file]
        }
        guard !all.isEmpty else {
            throw HPMError("no local config for '\(machine.name)' in \(dir) — run: hpm config pull \(machine.name)")
        }
        return all
    }
}
