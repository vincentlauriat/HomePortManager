import Foundation

/// Aggregate fleet state driving the menu bar icon.
public enum FleetHealth: Equatable {
    case allGreen
    case warning
    case unknown   // nothing declared to have an opinion about

    /// The icon is the third reading of the machine verdict, next to the status pill and the
    /// menu bar dot, so it goes through the same `severity(of:latest:)`.
    ///
    /// `nil` is a machine the app has declared but not yet observed, and it is passed in
    /// rather than filtered out: dropping it let the icon claim `allGreen` while the fleet
    /// table showed `CRITICAL` for that very machine. Unobserved weighs exactly what it
    /// weighs everywhere else — `severity(of: nil) == .critical`. `unknown` is therefore
    /// reserved for the one case where there is nothing to be green or red about: no
    /// machine declared at all.
    public static func aggregate(_ statuses: [MachineStatus?], latest: String?) -> FleetHealth {
        guard !statuses.isEmpty else { return .unknown }
        let allOK = statuses.allSatisfy { severity(of: $0, latest: latest) == .ok }
        return allOK ? .allGreen : .warning
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

/// The instant encoded in a backup archive name — `homeport_<machine>_<version>_<stamp>.tar.gz`
/// as `backup(on:)` writes it — or `nil` when there is no archive and when the name carries no
/// timestamp at all.
///
/// The single timestamp extraction of the kit. `backupAge` renders it as the CLI's compact
/// English age; the interface renders the same `Date` through a localized `FormatStyle`. Two
/// readings, one parser: a name either has an instant in it or it has none, and the two
/// surfaces can never disagree about which.
public func backupTimestamp(_ archiveName: String?) -> Date? {
    guard let archiveName,
          let stamp = archiveName.range(of: #"\d{8}-\d{6}"#, options: .regularExpression)
    else { return nil }
    return HomeportManager.timestampFormatter.date(from: String(archiveName[stamp]))
}

/// "2h ago", "3d ago" — backup age for menu rows, from the archive's timestamp suffix.
public func backupAge(_ archiveName: String?, now: Date = Date()) -> String {
    guard let date = backupTimestamp(archiveName) else { return "never" }
    let seconds = Int(now.timeIntervalSince(date))
    if seconds < 3_600 { return "\(max(seconds / 60, 0))m ago" }
    if seconds < 86_400 { return "\(seconds / 3_600)h ago" }
    return "\(seconds / 86_400)d ago"
}
