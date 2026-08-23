import Foundation
import SwiftUI
import HomePortKit

/// Owns the fleet, its statuses and the in-flight actions. All HomePortKit calls are
/// blocking ssh subprocesses, so they run detached; results come back on the main actor.
@MainActor
final class FleetModel: ObservableObject {
    @Published var machines: [Machine] = []
    @Published var statuses: [String: MachineStatus] = [:]
    @Published var latestTag: String?
    @Published var refreshing = false
    @Published var inFlight: Set<String> = []
    @Published var lastError: [String: String] = [:]
    /// Display cache, kept strictly apart from `statuses`: the last status in which each
    /// machine was reachable, and when that was. `statuses` must stay the raw observation
    /// because `transitions(old:new:)` — and therefore the menu bar notifications — reads
    /// it to detect a change of state.
    @Published var lastReachableStatus: [String: MachineStatus] = [:]
    @Published var lastSeenAt: [String: Date] = [:]
    /// Stable pastel identity per machine, assigned once and persisted.
    @Published var blocks: [String: MachineBlock] = [:]

    private let blockStore = MachineBlockStore()
    private var timer: Timer?
    private let makeManager: (@escaping Reporter) -> HomeportManager

    /// `map`, not `compactMap`: a declared machine with no status yet has to reach
    /// `aggregate` as a `nil` so the icon counts it. Filtering it out is what let the menu
    /// bar show a green check while the fleet table showed CRITICAL for the same machine.
    var health: FleetHealth {
        FleetHealth.aggregate(machines.map { statuses[$0.name] }, latest: latestTag)
    }

    init(makeManager: ((@escaping Reporter) -> HomeportManager)? = nil) {
        self.makeManager = makeManager ?? { report in
            let runner = DefaultProcessRunner()
            return HomeportManager(ssh: SSHClient(runner: runner),
                                   releases: ReleaseService(runner: runner),
                                   runner: runner, report: report)
        }
        Notifier.requestPermission()
        reloadFleet()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func reloadFleet() {
        let loaded = try? FleetStore().load().machines
        machines = loaded ?? []
        blocks = blockStore.blocks(for: machines.map(\.name))
        // Everything keyed by machine name is dropped for machines the file no longer
        // declares: a removed machine must not keep a status, a "last seen" or an error
        // behind the scenes, and a re-added one must start from a clean first observation
        // rather than from a stale comparison.
        //
        // Only when the file was actually read, though: an unreadable or half-written
        // fleet.yaml also yields an empty list, and wiping `statuses` on that would make the
        // next refresh look like a first observation for every machine — `transitions` would
        // stay silent through exactly the outage the menu bar exists to announce.
        //
        // `blocks` is never pruned either way: the block store is append-only so that a
        // colour is never handed to a second machine.
        guard let loaded else { return }
        let declared = Set(loaded.map(\.name))
        statuses = statuses.filter { declared.contains($0.key) }
        lastReachableStatus = lastReachableStatus.filter { declared.contains($0.key) }
        lastSeenAt = lastSeenAt.filter { declared.contains($0.key) }
        lastError = lastError.filter { declared.contains($0.key) }
    }

    /// The rows the global dashboard renders. Pure construction lives in the kit.
    func rows(matching filter: String = "") -> [FleetRow] {
        let all = fleetRows(machines: machines, statuses: statuses,
                            lastReachable: lastReachableStatus, lastSeen: lastSeenAt,
                            latest: latestTag, blocks: blocks)
        let needle = filter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }

    /// Last known data for a machine and when it was last seen — the couple every surface
    /// uses to keep showing something useful while a machine is unreachable.
    func displayStatus(for machine: Machine) -> (status: MachineStatus?, lastSeen: Date?) {
        let current = statuses[machine.name]
        let displayed = (current?.reachable == true) ? current : lastReachableStatus[machine.name]
        return (displayed, lastSeenAt[machine.name])
    }

    func block(for name: String) -> MachineBlock { blocks[name] ?? .lime }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        reloadFleet()
        let targets = machines
        let factory = makeManager
        Task.detached {
            let latest = try? factory { _ in }.releases.latest().tag
            var results = [String: MachineStatus]()
            await withTaskGroup(of: (String, MachineStatus?).self) { group in
                for machine in targets {
                    group.addTask { (machine.name, try? factory { _ in }.status(of: machine)) }
                }
                for await (name, status) in group { results[name] = status }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                for (name, status) in results {
                    for message in transitions(old: self.statuses[name], new: status) {
                        Notifier.notify(title: "HomePort", body: message)
                    }
                    self.statuses[name] = status
                    if status.reachable {
                        self.lastReachableStatus[name] = status
                        self.lastSeenAt[name] = Date()
                    }
                }
                if let latest { self.latestTag = latest }
                self.refreshing = false
            }
        }
    }

    enum Action: String {
        case backup = "Backup"
        case restart = "Restart"
        case update = "Update"

        /// The name shown to a human; `rawValue` stays the stable identifier.
        var title: String {
            switch self {
            case .backup: return String(localized: "Backup")
            case .restart: return String(localized: "Restart")
            case .update: return String(localized: "Update")
            }
        }
    }

    func run(_ action: Action, on machine: Machine) {
        guard !inFlight.contains(machine.name) else { return }
        inFlight.insert(machine.name)
        lastError[machine.name] = nil
        let factory = makeManager
        Task.detached {
            var failure: String?
            do {
                let manager = factory { _ in }
                switch action {
                case .backup: try manager.backup(on: machine)
                case .restart: try manager.restart(on: machine)
                case .update: try manager.update(on: machine, version: nil)
                }
            } catch {
                failure = "\(error)"
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.inFlight.remove(machine.name)
                if let failure {
                    self.lastError[machine.name] = failure
                    Notifier.notify(title: String(localized: "\(machine.name): \(action.title) failed"),
                                    body: failure)
                } else {
                    Notifier.notify(title: machine.name,
                                    body: String(localized: "\(action.title) finished"))
                }
                self.refresh()
            }
        }
    }

    func fetchLogs(for machine: Machine, lines: Int = 100) async -> String {
        let factory = makeManager
        return await Task.detached {
            do { return try factory { _ in }.logs(on: machine, lines: lines) }
            catch { return String(localized: "Unable to fetch logs: \(String(describing: error))") }
        }.value
    }
}
