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

    private var timer: Timer?
    private let makeManager: (@escaping Reporter) -> HomeportManager

    var health: FleetHealth {
        FleetHealth.aggregate(machines.compactMap { statuses[$0.name] }, latest: latestTag)
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
        machines = (try? FleetStore().load().machines) ?? []
    }

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
                    Notifier.notify(title: "\(machine.name): \(action.rawValue) failed", body: failure)
                } else {
                    Notifier.notify(title: machine.name, body: "\(action.rawValue) finished")
                }
                self.refresh()
            }
        }
    }

    func fetchLogs(for machine: Machine, lines: Int = 100) async -> String {
        let factory = makeManager
        return await Task.detached {
            do { return try factory { _ in }.logs(on: machine, lines: lines) }
            catch { return "unable to fetch logs: \(error)" }
        }.value
    }
}
