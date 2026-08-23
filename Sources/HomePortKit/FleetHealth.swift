import Foundation

/// Aggregate fleet state driving the menu bar icon.
public enum FleetHealth: Equatable {
    case allGreen
    case warning
    case unknown   // no data yet

    public static func aggregate(_ statuses: [MachineStatus], latest: String?) -> FleetHealth {
        guard !statuses.isEmpty else { return .unknown }
        let anyWarning = statuses.contains { !machineWarnings($0, latest: latest).isEmpty }
        return anyWarning ? .warning : .allGreen
    }
}

/// Human-readable warnings for one machine (empty = all good). Also used for rows
/// in the menu and for deciding the aggregate icon.
public func machineWarnings(_ status: MachineStatus, latest: String?) -> [String] {
    guard status.reachable else { return ["unreachable"] }
    var warnings: [String] = []
    if !status.serviceActive { warnings.append("service inactive") }
    if !status.healthzOK { warnings.append("healthz failing") }
    if let latest, status.installedVersion != "unknown", status.installedVersion != latest {
        warnings.append("update available (\(latest))")
    }
    if let disk = status.diskUsedPercent, disk >= 90 { warnings.append("disk \(disk)% full") }
    return warnings
}

/// Notification-worthy messages when a machine's state changes between two refreshes.
/// Transitions only — a machine staying red produces nothing.
public func transitions(old: MachineStatus?, new: MachineStatus) -> [String] {
    guard let old else { return [] }   // first observation: no notification
    var messages: [String] = []
    if old.reachable && !new.reachable {
        messages.append("\(new.name) is unreachable")
    } else if !old.reachable && new.reachable {
        messages.append("\(new.name) is reachable again")
    }
    if new.reachable && old.reachable {
        let oldGreen = old.serviceActive && old.healthzOK
        let newGreen = new.serviceActive && new.healthzOK
        if oldGreen && !newGreen { messages.append("\(new.name) is DOWN (service \(new.serviceActive ? "active" : "inactive"), healthz \(new.healthzOK ? "OK" : "failing"))") }
        if !oldGreen && newGreen { messages.append("\(new.name) is back up") }
    }
    return messages
}

/// "2h ago", "3d ago" — backup age for menu rows, from the archive's timestamp suffix.
public func backupAge(_ archiveName: String?, now: Date = Date()) -> String {
    guard let archiveName,
          let stampRange = archiveName.range(of: #"\d{8}-\d{6}"#, options: .regularExpression),
          let date = HomeportManager.timestampFormatter.date(from: String(archiveName[stampRange]))
    else { return "never" }
    let seconds = Int(now.timeIntervalSince(date))
    if seconds < 3_600 { return "\(max(seconds / 60, 0))m ago" }
    if seconds < 86_400 { return "\(seconds / 3_600)h ago" }
    return "\(seconds / 86_400)d ago"
}
