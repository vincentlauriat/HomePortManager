import Foundation

/// One line of the global dashboard: everything the fleet table renders for a machine,
/// already reduced to display values. Building it is pure so the view only draws.
public struct FleetRow: Equatable, Identifiable, Sendable {
    /// Carried by colour *and* label everywhere it is rendered — colour is never the sole
    /// carrier of state.
    public enum Severity: String, Equatable, Sendable {
        case ok
        case warning
        case critical
    }

    public let name: String
    public let block: MachineBlock
    public let severity: Severity
    /// The facts behind the severity, in the kit's documented order. Views render them
    /// through their own catalog rather than through the CLI's English prose.
    public let issues: [MachineIssue]
    /// `nil` when the machine has never been reached: the value is unknown, not empty.
    public let version: String?
    public let diskUsedPercent: Int?
    /// The instant of the last backup rather than a pre-rendered age: the age is a
    /// duration shown to a human, so it is formatted at the point of display with a
    /// localized `FormatStyle`. Both readings come from `backupTimestamp(_:)`; the kit's
    /// `backupAge(_:now:)` stays the CLI's compact form of the very same instant.
    public let lastBackupAt: Date?
    /// `nil` means "never seen since launch".
    public let lastSeen: Date?

    public var id: String { name }

    public init(name: String, block: MachineBlock, severity: Severity, issues: [MachineIssue],
                version: String?, diskUsedPercent: Int?, lastBackupAt: Date?, lastSeen: Date?) {
        self.name = name
        self.block = block
        self.severity = severity
        self.issues = issues
        self.version = version
        self.diskUsedPercent = diskUsedPercent
        self.lastBackupAt = lastBackupAt
        self.lastSeen = lastSeen
    }
}

/// Severity of a single machine, read off its issues — the one place a list of facts
/// becomes a colour.
///
/// Critical covers the three hard failures the design calls critical — unreachable, service
/// down, healthz failing — which is also what the menu bar dot has always shown in red.
/// Warning is reserved for a machine that answered and still needs attention (update
/// available, disk filling). A machine never polled yet is critical, like one never reached:
/// its state is not "fine", it is unknown.
///
/// Every surface — the pill, the sidebar dot, the menu bar dot — goes through this function,
/// so two views can never disagree about the same machine.
public func severity(of status: MachineStatus?, latest: String?) -> FleetRow.Severity {
    severity(of: machineIssues(status, latest: latest))
}

/// The severity carried by an already-computed issue list.
public func severity(of issues: [MachineIssue]) -> FleetRow.Severity {
    if issues.isEmpty { return .ok }
    return issues.contains(where: \.isCritical) ? .critical : .warning
}

/// Builds one row per declared machine, falling back to the last known data when the
/// machine is currently unreachable — an unreachable machine keeps its line, it never
/// disappears and never blanks out.
public func fleetRows(machines: [Machine],
                      statuses: [String: MachineStatus],
                      lastReachable: [String: MachineStatus] = [:],
                      lastSeen: [String: Date] = [:],
                      latest: String?,
                      blocks: [String: MachineBlock],
                      now: Date = Date()) -> [FleetRow] {
    machines.map { machine in
        let current = statuses[machine.name]
        let issues = machineIssues(current, latest: latest)
        // Displayed data comes from the current status when reachable, otherwise from the
        // last status that was; severity always comes from the *current* observation.
        let displayed: MachineStatus? = (current?.reachable == true)
            ? current
            : lastReachable[machine.name]
        return FleetRow(
            name: machine.name,
            block: blocks[machine.name] ?? .lime,
            severity: severity(of: issues),
            issues: issues,
            version: displayed?.installedVersion,
            diskUsedPercent: displayed?.diskUsedPercent,
            lastBackupAt: backupTimestamp(displayed?.lastBackup),
            lastSeen: lastSeen[machine.name])
    }
}
