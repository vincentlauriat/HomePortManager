import Foundation

extension HomeportManager {
    /// Full diagnosis: prerequisites, service, healthz, marker/healthz version
    /// coherence, data-dir disk usage, local config drift. Returns ✓/✗ checks;
    /// the CLI decides the exit code.
    public func doctor(on machine: Machine) throws -> [PrereqCheck] {
        try journaled("doctor", on: machine) { try performDoctor(on: machine) }
    }

    private func performDoctor(on machine: Machine) throws -> [PrereqCheck] {
        var checks = try prereqs(on: machine, fix: false)
        let status = try status(of: machine)

        checks.append(PrereqCheck(name: "service", ok: status.serviceActive,
                                  detail: status.serviceActive ? "" : "homeport.service is not active — try: hpm restart \(machine.name)"))
        checks.append(PrereqCheck(name: "healthz", ok: status.healthzOK,
                                  detail: status.healthzOK ? "" : "no answer on http://localhost:\(machine.port)/healthz — see: hpm logs \(machine.name)"))

        // Version coherence: the running code (healthz JSON) vs the installed marker.
        let body = try ssh.run(on: machine.ssh, "curl -fsS -m 5 http://localhost:\(machine.port)/healthz 2>/dev/null").stdout
        let runningVersion = (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
            .flatMap { $0?["version"] as? String }
        if let runningVersion {
            let marker = status.installedVersion
            let coherent = marker == "unknown" || marker.replacingOccurrences(of: "v", with: "") == runningVersion
            checks.append(PrereqCheck(name: "version", ok: coherent,
                                      detail: coherent ? "" : "running \(runningVersion) but \(marker) is on disk — the service runs stale code, try: hpm restart \(machine.name)"))
        }

        if let disk = status.diskUsedPercent {
            checks.append(PrereqCheck(name: "disk", ok: disk < 90,
                                      detail: disk < 90 ? "" : "data dir is \(disk)% full"))
        }

        // Config drift only when local copies exist (pull is optional).
        let localFiles = (try? FileManager.default.contentsOfDirectory(atPath: configDir(for: machine.name))) ?? []
        if !localFiles.isEmpty {
            let drift = try configDiff(on: machine, file: nil)
            checks.append(PrereqCheck(name: "config", ok: drift.isEmpty,
                                      detail: drift.isEmpty ? "" : "local copies differ from the machine — see: hpm config diff \(machine.name)"))
        }

        return checks
    }
}
