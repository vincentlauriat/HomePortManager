import Foundation

extension HomeportManager {
    /// Installs the given tag (nil → latest release). The Mac downloads the tarball and
    /// pushes it; the machine never contacts GitHub. Homeport's own install.sh does the
    /// heavy lifting and is idempotent.
    public func install(on machine: Machine, version: String?) throws {
        try journaled("install", on: machine, locking: true) { try performInstall(on: machine, version: version) }
    }

    private func performInstall(on machine: Machine, version: String?) throws {
        let tag = try version ?? releases.latest().tag
        report("Installing Homeport \(tag) on \(machine.name)…")

        let tarball = try releases.downloadTarball(tag: tag)
        report("Pushing \(tag) tarball…")
        try ssh.push(tarball, to: machine.ssh, remotePath: "/tmp/hpm-homeport.tar.gz")

        report("Running deploy/install.sh…")
        let script = """
        set -euo pipefail
        rm -rf /tmp/hpm-src
        mkdir -p /tmp/hpm-src
        tar -xzf /tmp/hpm-homeport.tar.gz -C /tmp/hpm-src --strip-components=1
        cd /tmp/hpm-src
        ./deploy/install.sh
        echo \(tag) > \(RemotePaths.versionMarker)
        rm -rf /tmp/hpm-src /tmp/hpm-homeport.tar.gz
        systemctl restart homeport
        """
        let result = try ssh.run(on: machine.ssh, script, sudo: true)
        guard result.succeeded else {
            let tail = result.stderr.split(separator: "\n").suffix(5).joined(separator: "\n")
            throw HPMError("install of \(tag) on \(machine.name) failed:\n\(tail)")
        }

        try checkHealth(on: machine)
        report("Homeport \(tag) is up on \(machine.name).")
    }

    /// Update = automatic backup, then the same idempotent install pipeline. One journal
    /// entry only: the nested backup and install see the depth guard and stay silent.
    public func update(on machine: Machine, version: String?) throws {
        try journaled("update", on: machine, locking: true) {
            report("Backing up \(machine.name) before update…")
            try backup(on: machine)
            try install(on: machine, version: version)
        }
    }

    /// healthz always checked from the machine itself (works regardless of how the
    /// HTTP port is exposed on the LAN/Tailscale).
    public func checkHealth(on machine: Machine, attempts: Int = 5, delaySeconds: Double = 2) throws {
        report("Checking healthz…")
        for attempt in 1...max(attempts, 1) {
            let result = try ssh.run(on: machine.ssh,
                                     "curl -fsS -m 5 http://localhost:\(machine.port)/healthz >/dev/null")
            if result.succeeded { return }
            if attempt < attempts { Thread.sleep(forTimeInterval: delaySeconds) }
        }
        throw HPMError("""
        healthz check failed on \(machine.name) (port \(machine.port)). \
        Inspect with: ssh \(machine.ssh) 'systemctl status homeport; journalctl -u homeport -n 30'
        """)
    }
}
