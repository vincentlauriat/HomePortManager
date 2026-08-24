import Foundation
import SwiftUI
import HomePortKit

/// Owns the fleet, its statuses and the in-flight actions. All HomePortKit calls are
/// blocking ssh subprocesses, so they run detached; results come back on the main actor.
@MainActor
final class FleetModel: ObservableObject {
    @Published var machines: [Machine] = []
    /// Non-nil when the last read of fleet.yaml failed. Distinguishes "the file does not
    /// parse" from "the file declares nothing" — two states that produce the same empty list.
    @Published var fleetLoadError: String?
    @Published var statuses: [String: MachineStatus] = [:]
    @Published var latestTag: String?
    @Published var refreshing = false
    /// The in-flight action per machine — what banner, buttons and menubar all observe.
    /// One entry per machine at most: the kit's inter-process lock refuses the rest, this
    /// dictionary is only the intra-app guard and the "… in progress" source.
    @Published var inFlight: [String: Action] = [:]
    /// The last action's persistent report per machine. `kind` keeps the headline
    /// honest: a doctor that *succeeded* but found failing checks is a `finding`,
    /// not a failed action — only real failures may be announced as such.
    @Published var lastError: [String: LastReport] = [:]
    /// The transient success confirmation the control center's toast overlay renders.
    /// Failures never toast: they get a persistent focus in the machine sheet instead.
    @Published var toast: Toast?
    /// Display cache, kept strictly apart from `statuses`: the last status in which each
    /// machine was reachable, and when that was. `statuses` must stay the raw observation
    /// because `transitions(old:new:)` — and therefore the menu bar notifications — reads
    /// it to detect a change of state.
    @Published var lastReachableStatus: [String: MachineStatus] = [:]
    @Published var lastSeenAt: [String: Date] = [:]
    /// Stable pastel identity per machine, assigned once and persisted.
    @Published var blocks: [String: MachineBlock] = [:]
    /// The task journal, newest first — Summary and Fleet render slices of this one list.
    @Published var tasks: [HistoryStore.TaskEntry] = []

    private let blockStore = MachineBlockStore()
    private var timer: Timer?
    private let makeManager: (@escaping Reporter) -> HomeportManager
    /// One shared store for the whole app: the model reads it, the managers built by the
    /// factory journal through it. nil when the state directory is unusable — the journal
    /// degrades, actions still run.
    private let history: HistoryStore?
    /// False when hpm.db could not be opened: the journal sections say so instead of
    /// pretending "no tasks yet" (the stderr warning is invisible for a menubar app).
    var historyAvailable: Bool { history != nil }

    /// `map`, not `compactMap`: a declared machine with no status yet has to reach
    /// `aggregate` as a `nil` so the icon counts it. Filtering it out is what let the menu
    /// bar show a green check while the fleet table showed CRITICAL for the same machine.
    var health: FleetHealth {
        FleetHealth.aggregate(machines.map { statuses[$0.name] }, latest: latestTag)
    }

    init(makeManager: ((@escaping Reporter) -> HomeportManager)? = nil) {
        let history: HistoryStore?
        do {
            history = try HistoryStore()
        } catch {
            FileHandle.standardError.write(Data("warning: task journal unavailable — \(error)\n".utf8))
            history = nil
        }
        self.history = history
        self.makeManager = makeManager ?? { report in
            let runner = DefaultProcessRunner()
            return HomeportManager(ssh: SSHClient(runner: runner),
                                   releases: ReleaseService(runner: runner),
                                   runner: runner, history: history, report: report)
        }
        Notifier.requestPermission()
        // This init is *the* app startup hook (no AppDelegate; the MenuBarExtra's
        // `.onAppear` only fires when the menu opens), so retention runs here — the app
        // alone purges, the CLI never does. Off the MainActor: SQLite work is blocking.
        if let history {
            Task.detached { [weak self] in
                do {
                    _ = try history.purge()
                } catch {
                    // The app is the only purge site (NFR7): a failure must leave a
                    // trace somewhere, or retention silently stops being enforced.
                    FileHandle.standardError.write(Data("warning: task journal purge failed — \(error)\n".utf8))
                }
                await self?.reloadTasks()
            }
        }
        reloadFleet()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func reloadFleet() {
        // The error is kept, not swallowed: an unreadable or half-written fleet.yaml yields
        // the same empty list as a file that declares nothing, and the empty state then
        // invites a user whose file *does* declare machines to add a first one. The reload
        // button rendered neither success nor failure.
        let loaded: [Machine]?
        do {
            loaded = try FleetStore().load().machines
            fleetLoadError = nil
        } catch {
            loaded = nil
            fleetLoadError = "\(error)"
        }
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

    /// Monotonic guard against out-of-order publication: an action-completion reload
    /// racing the periodic refresh's must never let the older snapshot land last.
    /// MainActor-confined, like every caller of `reloadTasks`.
    private var reloadGeneration = 0

    /// Reads are free and parallel; the blocking SQLite call still stays off the
    /// MainActor. The limit is the retention cap: the base never holds more, and any
    /// smaller slice could starve a quiet machine's "Recent tasks" (that view filters
    /// this list client-side). Outputs stay in the base — no list surface renders them.
    /// A failed read keeps the previous list — publishing an empty one on a transient
    /// SQLITE_BUSY would wipe the journal off the screen.
    func reloadTasks() {
        guard let history else { return }
        reloadGeneration += 1
        let generation = reloadGeneration
        Task.detached {
            let entries: [HistoryStore.TaskEntry]
            do {
                entries = try history.tasks(limit: HistoryStore.retentionCap,
                                            includeOutput: false)
            } catch {
                // Keeping the previous list is right for a transient SQLITE_BUSY, but a
                // persistent failure (corrupt row) must not stay invisible — same trace
                // channel as the purge and journal-write failures.
                FileHandle.standardError.write(Data("warning: task journal read failed — \(error)\n".utf8))
                return
            }
            await MainActor.run { [weak self] in
                guard let self, generation == self.reloadGeneration else { return }
                // Most 5-minute ticks change nothing: skip the publication (and the
                // SwiftUI re-diff of both journal tables) when the snapshot is identical.
                if entries != self.tasks { self.tasks = entries }
            }
        }
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        reloadFleet()
        reloadTasks()
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

    enum Action: String, Identifiable, CaseIterable {
        case backup = "Backup"
        case restart = "Restart"
        case doctor = "Doctor"
        case config = "Config"
        case update = "Update"
        case restore = "Restore"
        case remove = "Remove"

        var id: String { rawValue }

        /// Destructive actions confirm through the UX-DR6 sheet before running.
        var isDestructive: Bool {
            switch self {
            case .update, .restore, .remove: return true
            case .backup, .restart, .doctor, .config: return false
            }
        }

        /// The name shown to a human; `rawValue` stays the stable identifier.
        var title: String {
            switch self {
            case .backup: return String(localized: "Backup")
            case .restart: return String(localized: "Restart")
            case .doctor: return String(localized: "Doctor")
            case .config: return String(localized: "Config")
            case .update: return String(localized: "Update")
            case .restore: return String(localized: "Restore")
            case .remove: return String(localized: "Remove")
            }
        }

        /// The banner's "… in progress" line. Per-action keys rather than one composed
        /// sentence: French genders the past participle by action, one pattern cannot.
        var progressLabel: LocalizedStringKey {
            switch self {
            case .backup: return "Backup in progress…"
            case .restart: return "Restart in progress…"
            case .doctor: return "Doctor in progress…"
            case .config: return "Config pull in progress…"
            case .update: return "Update in progress…"
            case .restore: return "Restore in progress…"
            case .remove: return "Remove in progress…"
            }
        }

    }

    /// What the machine sheet's persistent focus (and the menubar line) shows, and as
    /// what: an action that threw (`failure`), or one that succeeded while reporting
    /// problems — doctor's failing checks (`finding`).
    struct LastReport: Equatable {
        enum Kind: Equatable { case failure, finding }
        let kind: Kind
        /// Machine output: shown as produced, never translated.
        let message: String
    }

    /// One success confirmation, already worded: doctor and config toast their actual
    /// result (check verdict, file count), the rest a past-tense "finished". The `id`
    /// makes consecutive identical toasts two events, so the auto-dismiss timer restarts.
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let machine: String
        let message: LocalizedStringKey
    }

    func dismissToast(_ id: UUID) {
        if toast?.id == id { toast = nil }
    }

    /// Publishes the toast and schedules its own dismissal. The timer lives in the model,
    /// not the overlay view: a toast born from a menubar action before the control center
    /// window ever existed would otherwise linger until the window opens — and greet it
    /// with a stale success hours later.
    private func showToast(machine: String, message: LocalizedStringKey) {
        let shown = Toast(machine: machine, message: message)
        toast = shown
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            self?.dismissToast(shown.id)
        }
    }

    func run(_ action: Action, on machine: Machine) {
        guard inFlight[machine.name] == nil else {
            // A confirmation landing while the machine already mutates (menubar race, a
            // sheet confirmed late) must refuse visibly, never evaporate silently.
            lastError[machine.name] = LastReport(
                kind: .failure,
                message: String(localized: "Another action is already in progress on this machine."))
            return
        }
        inFlight[machine.name] = action
        lastError[machine.name] = nil
        // Frozen on the MainActor at confirmation time: the sheet's consequence names
        // this tag, so this is the version the update must install — not whatever is
        // latest by the time the detached task runs.
        let pinnedVersion = action == .update ? latestTag : nil
        let factory = makeManager
        Task.detached {
            var failure: String?
            var toastMessage: LocalizedStringKey?
            // The system notification's mirror of the toast: same catalog keys, but a
            // plain String — the menubar reader gets the same verdict as the window.
            var note: String?
            var problem: String?
            do {
                let manager = factory { _ in }
                switch action {
                case .backup:
                    try manager.backup(on: machine)
                    toastMessage = "Backup finished"
                    note = String(localized: "Backup finished")
                case .restart:
                    try manager.restart(on: machine)
                    toastMessage = "Restart finished"
                    note = String(localized: "Restart finished")
                case .doctor:
                    // The checks are the result: a doctor that found problems must not
                    // toast like a plain success — the toast carries the verdict and the
                    // failing checks get the persistent error focus in the sheet.
                    let failing = try manager.doctor(on: machine).filter { !$0.ok }
                    if failing.isEmpty {
                        toastMessage = "Doctor: all checks passed"
                        note = String(localized: "Doctor: all checks passed")
                    } else {
                        toastMessage = "Doctor: \(failing.count) failed check(s)"
                        note = String(localized: "Doctor: \(failing.count) failed check(s)")
                        problem = failing
                            .map { "✗ \($0.name)\($0.detail.isEmpty ? "" : " — \($0.detail)")" }
                            .joined(separator: "\n")
                    }
                case .config:
                    let files = try manager.configPull(from: machine)
                    toastMessage = "Config: \(files.count) file(s) pulled"
                    note = String(localized: "Config: \(files.count) file(s) pulled")
                case .update:
                    try manager.update(on: machine, version: pinnedVersion)
                    toastMessage = "Update finished"
                    note = String(localized: "Update finished")
                // The app's Restore is always the most recent local archive; picking a
                // specific one stays a CLI capability.
                case .restore:
                    try manager.restore(on: machine, archive: nil)
                    toastMessage = "Restore finished"
                    note = String(localized: "Restore finished")
                case .remove:
                    try manager.remove(on: machine)
                    toastMessage = "Remove finished"
                    note = String(localized: "Remove finished")
                }
            } catch {
                failure = "\(error)"
            }
            // Frozen before crossing to the MainActor: captured `var`s in concurrent
            // code are an error in the Swift 6 language mode.
            let outcome = (failure: failure, toast: toastMessage, note: note, problem: problem)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.inFlight[machine.name] = nil
                if let failure = outcome.failure {
                    // The failure gets a persistent focus in the machine sheet
                    // (`lastError`); the system notification is kept for the menubar.
                    self.lastError[machine.name] = LastReport(kind: .failure, message: failure)
                    Notifier.notify(title: String(localized: "\(machine.name): \(action.title) failed"),
                                    body: failure)
                } else {
                    // nil clears a stale intra-app refusal written while this action ran:
                    // a succeeded action must not leave "another action in progress" behind.
                    self.lastError[machine.name] = outcome.problem.map { LastReport(kind: .finding, message: $0) }
                    if let message = outcome.toast {
                        self.showToast(machine: machine.name, message: message)
                    }
                    Notifier.notify(title: machine.name,
                                    body: outcome.note ?? String(localized: "\(action.title) finished"))
                }
                // Not left to refresh() alone: its `guard !refreshing` can swallow the
                // reload when the periodic refresh is in flight, and the just-closed
                // task would only appear at the next cycle.
                self.reloadTasks()
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

    // MARK: - Logs tab (FR4)

    /// The two log reads of the Logs tab, going through the same manager factory as every
    /// other remote call — the app builds no second `SSHClient` of its own. Unlike
    /// `fetchLogs`, which the menu bar's Logs window renders as text whatever happens, these
    /// two throw: the tab needs the verdict to choose its empty state.
    ///
    /// Reads, both of them: no lock is taken and nothing is journaled.
    func startLogFollow(for machine: Machine, lines: Int = LogDefaults.tail) async throws -> ProcessOutputStream {
        let factory = makeManager
        return try await Task.detached {
            try factory { _ in }.followLogs(on: machine, lines: lines)
        }.value
    }

    func logSnapshot(for machine: Machine, lines: Int = LogDefaults.tail) async throws -> String {
        let factory = makeManager
        return try await Task.detached {
            try factory { _ in }.logs(on: machine, lines: lines)
        }.value
    }
}
