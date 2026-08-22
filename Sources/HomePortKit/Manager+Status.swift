import Foundation

public struct MachineStatus: Equatable {
    public let name: String
    public let reachable: Bool
    public let installedVersion: String
    public let serviceActive: Bool
    public let healthzOK: Bool
    public let lastBackup: String?

    public init(name: String, reachable: Bool, installedVersion: String,
                serviceActive: Bool, healthzOK: Bool, lastBackup: String?) {
        self.name = name
        self.reachable = reachable
        self.installedVersion = installedVersion
        self.serviceActive = serviceActive
        self.healthzOK = healthzOK
        self.lastBackup = lastBackup
    }
}

extension HomeportManager {
    /// Fleet status for one machine. A down machine yields reachable=false instead of
    /// throwing, so `hpm status --all` always renders a full table.
    public func status(of machine: Machine) throws -> MachineStatus {
        let lastBackup = latestLocalBackup(for: machine.name).map { ($0 as NSString).lastPathComponent }
        let command = """
        cat \(RemotePaths.versionMarker) 2>/dev/null; echo ::; \
        systemctl is-active \(RemotePaths.unit) 2>/dev/null; echo ::; \
        curl -fsS -m 5 http://localhost:\(machine.port)/healthz >/dev/null 2>&1 && echo OK || echo FAIL
        """

        let result: CommandResult
        do {
            result = try ssh.run(on: machine.ssh, command)
        } catch is HPMError {
            return MachineStatus(name: machine.name, reachable: false, installedVersion: "-",
                                 serviceActive: false, healthzOK: false, lastBackup: lastBackup)
        }

        let parts = result.stdout
            .components(separatedBy: "::")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let version = parts.count > 0 && !parts[0].isEmpty ? parts[0] : "unknown"
        let serviceActive = parts.count > 1 && parts[1] == "active"
        let healthzOK = parts.count > 2 && parts[2].contains("OK")

        return MachineStatus(name: machine.name, reachable: true, installedVersion: version,
                             serviceActive: serviceActive, healthzOK: healthzOK, lastBackup: lastBackup)
    }
}
