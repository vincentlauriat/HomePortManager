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
    /// The latest tagged release's notes (GitHub's release body), fetched alongside
    /// `latestTag` in the same cycle — the Updates tab's only source for them, no second
    /// `ReleaseService` call. A failed fetch leaves both this and `latestTag` at their
    /// previous value; a successful one always overwrites this with the just-fetched
    /// release's notes, nil included, so a release published without notes clears it.
    @Published var latestReleaseNotes: String?
    /// True only after a releases fetch has actually thrown — distinct from `latestTag`
    /// being nil before the very first cycle has resolved. The Updates tab needs this to
    /// tell "not loaded yet" (show the installed version, say nothing about updates) from
    /// "GitHub unreachable" (a real empty state) instead of conflating both into one.
    @Published var releasesUnavailable = false
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
    /// Not `private`: `MaintenanceTabView` needs the exact same `let factory = makeManager;
    /// Task.detached { let manager = factory { _ in } … }` shape every mutation here already
    /// uses (Global Constraint — never a cached manager instance, and the manager must be
    /// built *inside* the detached task, or the non-`Sendable` `HomeportManager` would cross
    /// the boundary instead of the `Sendable` factory closure). A second, separately
    /// constructed `HomeportManager` would also open its own `HistoryStore`, breaking "one
    /// shared store for the whole app" (`history` below) that `journaled`'s lock and journal
    /// depend on.
    let makeManager: (@escaping Reporter) -> HomeportManager
    /// One shared store for the whole app: the model reads it, the managers built by the
    /// factory journal through it. nil when the state directory is unusable — the journal
    /// degrades, actions still run.
    private let history: HistoryStore?
    /// False when hpm.db could not be opened: the journal sections say so instead of
    /// pretending "no tasks yet" (the stderr warning is invisible for a menubar app).
    var historyAvailable: Bool { history != nil }

    /// Where the events cursors live (story 2.2a, AD-6). Exposed rather than wrapped: the
    /// Events tab hands it to `HomeportEventsReader`, and the app is that cursor's only
    /// writer — `hpm events` reads without moving it. nil when hpm.db could not be opened,
    /// which costs the reset detection and nothing else.
    var eventCursors: EventCursorStore? { history }

    /// Where the notification markers live (story 2.2b, AD-6) — a second, independent
    /// position in the same history, never merged with `eventCursors`. The background poll
    /// below is this marker's only writer.
    var notifiedMarkers: NotifiedMarkerStore? { history }

    /// 45 s, shared with `EventsTabView`'s own poll interval. Lives here rather than on the
    /// view: a model type must not depend on a view type for its own cadence (Code Map).
    static let eventsPollInterval: Duration = .seconds(45)

    /// Sticky per machine: `true` once a background poll's `.window` read has succeeded at
    /// least once, `false` only after an explicit `.unavailable`, unchanged (absent =
    /// "never observed") on a transient failure (`eventsPolicyAvailability`). `refresh()`
    /// reads this to gate the SSH `transitions()` policy — single-policy (AD, epic 2): a
    /// machine on the events policy never also gets a menu-bar transition notification.
    @Published var eventsAvailable: [String: Bool] = [:]

    /// One client for the whole app's background notification poll — never the Events
    /// tab's own `EventFeedStore.api`, which belongs to that surface's read cursor only.
    private let notificationsAPI = HomeportAPIClient()
    private var notificationsPollTask: Task<Void, Never>?
    /// One trace, not one every 45 s, when hpm.db turns out to be unavailable.
    private var notifiedMarkerStoreWarned = false

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
        Notifier.model = self
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
        // Story 2.2b: independent of the Events tab and of its own poll loop — this one
        // runs from app launch, machine sheet open or not (Code Map), and never touches
        // `event_cursors` (AD-6). Polls immediately, then every `eventsPollInterval`.
        notificationsPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollEventsForNotifications()
                try? await Task.sleep(for: Self.eventsPollInterval)
            }
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
        // Story 2.2b's sticky policy flag is keyed by machine name like the rest: a
        // re-added machine must be re-observed before its SSH transitions are silenced
        // again, never inherit an events policy from a previous life. The `guard` in
        // `pollEvents` below leans on this prune to keep an in-flight poll from putting
        // the entry back — the two only work as a pair.
        eventsAvailable = eventsAvailable.filter { declared.contains($0.key) }
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
            let latest = try? factory { _ in }.releases.latest()
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
                    // Single-policy (epic 2, AD): a machine the background poll has put on
                    // the events policy never also gets an SSH-transition notification.
                    // Absent (never observed) keeps today's behaviour — the SSH policy.
                    if self.eventsAvailable[name] != true {
                        for message in transitions(old: self.statuses[name], new: status) {
                            Notifier.notify(title: "HomePort", body: message)
                        }
                    }
                    self.statuses[name] = status
                    if status.reachable {
                        self.lastReachableStatus[name] = status
                        self.lastSeenAt[name] = Date()
                    }
                }
                if let latest {
                    self.latestTag = latest.tag
                    self.latestReleaseNotes = latest.notes
                    self.releasesUnavailable = false
                } else {
                    self.releasesUnavailable = true
                }
                self.refreshing = false
            }
        }
    }

    // MARK: - Notification poll (story 2.2b)

    /// One tour of the background poll: every declared machine, sequentially — HTTP is
    /// already async I/O and NFR6 caps the fleet under 10 machines, so a task group buys
    /// nothing a plain loop does not already give for free.
    private func pollEventsForNotifications() async {
        // No hpm.db means no marker: every tour would re-initialize silently and never
        // notify anything, while `eventsAvailable` would still switch machines onto the
        // events policy and silence their SSH transitions — total silence on both
        // channels. Staying entirely out of the poll keeps them on the SSH policy, which
        // is the honest fallback. Traced once, not every 45 s.
        guard notifiedMarkers != nil else {
            if !notifiedMarkerStoreWarned {
                notifiedMarkerStoreWarned = true
                FileHandle.standardError.write(Data(
                    "warning: hpm.db is unavailable — critical-event notifications are off, machines stay on the SSH-transition policy\n".utf8))
            }
            return
        }
        let reader = HomeportEventsReader(api: notificationsAPI, cursors: nil)
        for machine in machines {
            await pollEvents(for: machine, reader: reader)
        }
    }

    /// One machine's tour: `.window`, `advancingCursor: false`, `cursors: nil` — the reset
    /// detection is self-contained on the notified marker's own epoch (Code Map), so this
    /// poll never needs `event_cursors` and never touches it (AD-6).
    private func pollEvents(for machine: Machine, reader: HomeportEventsReader) async {
        let read = await reader.read(machine, mode: .window, advancingCursor: false)
        // A machine retired from fleet.yaml mid-poll must not leave a stale entry behind
        // once `reloadFleet()` has already pruned everything else keyed by its name.
        guard machines.contains(where: { $0.name == machine.name }) else { return }
        guard let available = eventsPolicyAvailability(for: read) else { return }
        eventsAvailable[machine.name] = available
        guard available, case .window(let window) = read else { return }
        // A double-stale read — the epoch flipped during two consecutive full pulls
        // (`Manager+Events.swift`) — reports a generation it never managed to read as an
        // empty history at `latestID` 0. Initializing the marker there would make the
        // next poll see that whole generation as new and notify it retroactively, which
        // "jamais rétroactif" forbids. With `cursors: nil` this poll has no stored cursor
        // to compare against, so `cursorWasReset` can only come from that path here.
        if window.cursorWasReset, window.events.isEmpty, window.latestID == 0 { return }

        // A read failure here (corrupt hpm.db) must surface as a trace, never be
        // swallowed by `try?` into "never notified" — that would silently re-notify
        // everything already seen, or worse, silently skip a real reset.
        let stored: NotifiedMarker?
        do {
            stored = try notifiedMarkers?.notifiedMarker(machine: machine.name)
        } catch {
            FileHandle.standardError.write(Data(
                "warning: could not read the notified marker for \(machine.name) — \(error)\n".utf8))
            return
        }
        let decision = notifiableCriticalEvents(in: window, notifiedMarker: stored)
        for event in decision.toNotify {
            Notifier.notifyCriticalEvent(machine: machine.name, event: event)
        }
        // Nothing moved: a quiet machine must not cost one SQLite write per 45 s just to
        // refresh `updated_at`.
        guard decision.newMarker != stored else { return }
        do {
            try notifiedMarkers?.setNotifiedMarker(decision.newMarker, machine: machine.name, now: Date())
        } catch {
            FileHandle.standardError.write(Data(
                "warning: could not store the notified marker for \(machine.name) — \(error)\n".utf8))
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

        /// Whether the action confirms through a sheet before running.
        ///
        /// Wider than `isDestructive` on purpose. A restart is not destructive — nothing is
        /// lost — but it stops the service a production machine is serving with, and it used
        /// to fire on the first click. The menu bar has always confirmed it
        /// (`MenuContent.swift`, "Restart homeport on …?"), so the control center firing it
        /// bare made the same action safe on one surface and not the other.
        ///
        /// Deviation from the story 1.3 spec, which lists Restart among the direct actions.
        /// Raised and decided by Vincent on 2026-08-24.
        var needsConfirmation: Bool {
            switch self {
            case .update, .restore, .remove, .restart: return true
            case .backup, .doctor, .config: return false
            }
        }

        /// Whether the action destroys something. Drives colour only — UX-DR6 reserves the
        /// red ground for these three, so a confirmed restart stays an ordinary pill.
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
