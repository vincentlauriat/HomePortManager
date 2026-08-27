import Foundation

/// Everything that can be wrong with one machine, as facts rather than sentences.
///
/// `machineWarnings(_:latest:)` answers the same question for the CLI, but it answers it in
/// English prose the CLI owns and no interface can translate. This enum is that same rule
/// set expressed once, so the menu bar, the fleet table and the machine sheet all read a
/// single verdict instead of each re-deriving one.
public enum MachineIssue: Equatable, Sendable {
    /// No observation at all yet — unknown, which is not the same as fine.
    case notPolled
    case unreachable
    case serviceInactive
    case healthzFailing
    /// Carries the used percentage that crossed the threshold.
    case diskAlmostFull(Int)
    /// Carries the release the machine could move to.
    case updateAvailable(String)

    /// The three hard failures plus "never observed": a machine in any of these states is
    /// critical, never merely worth a look.
    public var isCritical: Bool {
        switch self {
        case .notPolled, .unreachable, .serviceInactive, .healthzFailing: return true
        case .diskAlmostFull, .updateAvailable: return false
        }
    }
}

/// The issues of one machine, in a stable documented order.
///
/// Order — and the rules themselves — mirror `machineWarnings(_:latest:)` exactly, which is
/// the point: the CLI and the interface must never disagree about the same machine. An
/// unobserved or unreachable machine yields that single fact; nothing else can be said about
/// it. Then, for a machine that answered: service, health check, available update, disk.
///
/// Thresholds live here and only here: disk at `>= 90`, and an update is only claimed when
/// the installed version is actually known (`"unknown"` is the parser's marker for "the
/// version marker was unreadable", never a version to compare against).
public func machineIssues(_ status: MachineStatus?, latest: String?) -> [MachineIssue] {
    guard let status else { return [.notPolled] }
    guard status.reachable else { return [.unreachable] }
    var issues: [MachineIssue] = []
    if !status.serviceActive { issues.append(.serviceInactive) }
    if !status.healthzOK { issues.append(.healthzFailing) }
    if let target = updateTarget(installed: status.installedVersion, latest: latest) {
        issues.append(.updateAvailable(target))
    }
    if let disk = status.diskUsedPercent, disk >= 90 { issues.append(.diskAlmostFull(disk)) }
    return issues
}

/// The release an installed version should move to, or nil if it's already current (or
/// there's nothing to compare against). The single source of truth for "is this version
/// behind `latest`" — `machineIssues` uses it for the live verdict; a caller reasoning about
/// a stale/last-known installed version (a machine currently unreachable) calls it directly
/// instead of re-deriving the same three-way comparison.
public func updateTarget(installed: String, latest: String?) -> String? {
    guard let latest, installed != "unknown", installed != latest else { return nil }
    return latest
}
