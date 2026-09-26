import Foundation

public struct MachineStatus: Equatable {
    public let name: String
    public let reachable: Bool
    public let installedVersion: String
    public let serviceActive: Bool
    public let healthzOK: Bool
    public let lastBackup: String?
    public let uptimeSeconds: Int?
    public let diskUsedPercent: Int?
    public let sshLatencyMs: Int?

    public init(name: String, reachable: Bool, installedVersion: String,
                serviceActive: Bool, healthzOK: Bool, lastBackup: String?,
                uptimeSeconds: Int? = nil, diskUsedPercent: Int? = nil, sshLatencyMs: Int? = nil) {
        self.name = name
        self.reachable = reachable
        self.installedVersion = installedVersion
        self.serviceActive = serviceActive
        self.healthzOK = healthzOK
        self.lastBackup = lastBackup
        self.uptimeSeconds = uptimeSeconds
        self.diskUsedPercent = diskUsedPercent
        self.sshLatencyMs = sshLatencyMs
    }
}

extension HomeportManager {
    /// Fleet status for one machine — a single combined ssh call gathers version,
    /// service state, healthz, service uptime and data-dir disk usage. A down machine
    /// yields reachable=false instead of throwing, so `hpm status --all` always
    /// renders a full table.
    public func status(of machine: Machine) throws -> MachineStatus {
        let lastBackup = latestLocalBackup(for: machine.name).map { ($0 as NSString).lastPathComponent }
        let command = """
        cat \(RemotePaths.versionMarker) 2>/dev/null; echo ::; \
        if command -v systemctl >/dev/null 2>&1; then systemctl is-active \(RemotePaths.unit) 2>/dev/null; \
        else launchctl print "gui/$(id -u)/\(RemotePaths.launchdLabel)" 2>/dev/null | grep -q 'state = running' && echo active || echo inactive; fi; echo ::; \
        curl -fsS -m 5 http://localhost:\(machine.port)/healthz >/dev/null 2>&1 && echo OK || echo FAIL; echo ::; \
        TS=$(systemctl show \(RemotePaths.unit) -p ActiveEnterTimestamp --value 2>/dev/null); \
        { [ -n "$TS" ] && date -d "$TS" +%s >/dev/null 2>&1 && echo $(( $(date +%s) - $(date -d "$TS" +%s) )); } || echo ''; echo ::; \
        ENVV=$(systemctl show \(RemotePaths.unit) -p Environment 2>/dev/null | sed 's/^Environment=//'); \
        DATA=$(printf '%s\\n' $ENVV | grep '^HOMEPORT_DATA_DIR=' | tail -1 | cut -d= -f2-); \
        df --output=pcent "${DATA:-\(RemotePaths.data)}" 2>/dev/null | tail -1
        """

        let started = Date()
        let result: CommandResult
        do {
            result = try ssh.run(on: machine.ssh, command)
        } catch is HPMError {
            return MachineStatus(name: machine.name, reachable: false, installedVersion: "-",
                                 serviceActive: false, healthzOK: false, lastBackup: lastBackup)
        }
        let latencyMs = Int(Date().timeIntervalSince(started) * 1000)

        let parts = result.stdout
            .components(separatedBy: "::")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let version = parts.count > 0 && !parts[0].isEmpty ? parts[0] : "unknown"
        let serviceActive = parts.count > 1 && parts[1] == "active"
        let healthzOK = parts.count > 2 && parts[2].contains("OK")
        let uptime = parts.count > 3 ? Int(parts[3]) : nil
        let disk = parts.count > 4 ? Int(parts[4].replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) : nil

        return MachineStatus(name: machine.name, reachable: true, installedVersion: version,
                             serviceActive: serviceActive, healthzOK: healthzOK, lastBackup: lastBackup,
                             uptimeSeconds: uptime, diskUsedPercent: disk, sshLatencyMs: latencyMs)
    }
}

/// "3d 4h", "2h 05m", "47s" — for the status table and the menu bar app.
public func formatUptime(_ seconds: Int?) -> String {
    guard let seconds, seconds >= 0 else { return "-" }
    let days = seconds / 86_400
    let hours = (seconds % 86_400) / 3_600
    let minutes = (seconds % 3_600) / 60
    if days > 0 { return "\(days)d \(hours)h" }
    if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
    if minutes > 0 { return "\(minutes)m" }
    return "\(seconds)s"
}
