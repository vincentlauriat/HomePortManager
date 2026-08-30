import SwiftUI
import HomePortKit

/// The eight tabs of a machine sheet, in the order the epic fixes. Their raw values are the
/// ⌘1…⌘8 shortcuts, so the numbering is the contract, not an accident of ordering.
enum MachineTab: Int, CaseIterable, Identifiable, Hashable {
    case summary = 1
    case dashboard
    case logs
    case events
    case metrics
    case backups
    case shell
    case updates

    var id: Int { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .summary: return "Summary"
        case .dashboard: return "Dashboard"
        case .logs: return "Logs"
        case .events: return "Events"
        case .metrics: return "Metrics"
        case .backups: return "Backups"
        case .shell: return "Shell"
        case .updates: return "Updates"
        }
    }

    /// What is not here yet, and which story brings it. The spec asks each empty tab to name
    /// its story, not just its epic: the numbers below are the sprint-status keys, so a tab
    /// that starts lying is caught the moment the plan changes.
    var pendingMessage: LocalizedStringKey? {
        switch self {
        case .summary, .dashboard, .logs, .events, .metrics, .updates: return nil
        case .backups: return "Backup jobs and restores arrive with story 3.2, archive consolidation and the job view."
        case .shell: return "The embedded terminal arrives with story 3.4, the embedded shell."
        }
    }

    /// Tabs that take the whole sheet and scroll inside their own surface. Nesting them in
    /// the sheet's `ScrollView` would collapse their height and fight their wheel events —
    /// true of the dashboard's web view and of the log viewer alike.
    /// Every case is named rather than defaulted: a tab added to the enum has to answer this
    /// question explicitly, which is also what makes `fullTab`'s exhaustive switch the visible
    /// failure it claims to be — a `default:` here would route the new tab away from it.
    var fillsSheet: Bool {
        switch self {
        case .dashboard, .logs, .events: return true
        case .summary, .metrics, .backups, .shell, .updates: return false
        }
    }
}

/// A machine sheet: its coloured banner, the eight tabs, and a populated Summary. The seven
/// other tabs exist, take focus, answer their shortcut and say what will fill them.
struct MachineDetailView: View {
    @ObservedObject var model: FleetModel
    @ObservedObject var commands: ControlCenterCommands
    /// Owned by the window's root view: the dashboard's page state and the log sessions
    /// must survive this view, which `.id(machine.name)` recreates on every machine switch.
    let webCache: DashboardWebCache
    let logSessions: LogSessionStore
    /// The events feeds, owned by the window for the same reason the two above are.
    let eventFeeds: EventFeedStore
    /// The metrics feeds, likewise: a range picked on a machine must survive the tab
    /// switch that recreates the view, and an outage must not blank the curves behind it.
    let metrics: MetricsStore
    let machine: Machine

    @State private var tab: MachineTab = .summary
    @FocusState private var focusedTab: MachineTab?
    /// The destructive action awaiting its UX-DR6 confirmation sheet.
    @State private var pendingAction: FleetModel.Action?

    private var display: (status: MachineStatus?, lastSeen: Date?) {
        model.displayStatus(for: machine)
    }

    /// One health verdict for the whole sheet, read from the kit — the banner pill, the
    /// summary pill and the reasons under it are three renderings of this single list.
    private var issues: [MachineIssue] {
        machineIssues(model.statuses[machine.name], latest: model.latestTag)
    }

    private var severity: FleetRow.Severity { HomePortKit.severity(of: issues) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            MachineBanner(name: machine.name, host: machine.ssh,
                          block: model.block(for: machine.name), severity: severity,
                          activity: model.inFlight[machine.name]?.progressLabel)
            tabBar
            if tab.fillsSheet {
                fullTab
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    content
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(Theme.Spacing.lg)
        .onChange(of: commands.signal) { signal in
            guard case .selectTab(let index)? = signal?.command,
                  let requested = MachineTab(rawValue: index) else { return }
            tab = requested
        }
        // ⌘1…⌘8 only exist while a machine sheet is showing; on the fleet view they must
        // travel back up the responder chain rather than be swallowed. The journal can
        // advance from the CLI while no window shows, so it reloads on appearance too.
        .onAppear {
            commands.handling(.selectTab, true)
            model.reloadTasks()
            applyPendingNavigation()
        }
        .onDisappear { commands.handling(.selectTab, false) }
        // Story 2.2b's click-to-navigate, the tab half: `onAppear` catches a fresh sheet
        // (`.id(machine.name)` just created it for the machine the click named); `onChange`
        // catches a second click for the *same* machine already on screen, which recreates
        // nothing and so never re-fires `onAppear`.
        .onChange(of: commands.pendingNavigation) { _ in applyPendingNavigation() }
        // The UX-DR6 confirmation. `.sheet`'s native scrim is the dimming; ⌘-shortcuts
        // stay routed by `ControlCenterNSWindow.performKeyEquivalent` while it shows.
        .sheet(item: $pendingAction) { action in
            ConfirmationSheet(title: sheetTitle(action),
                              consequence: sheetConsequence(action),
                              confirmTitle: sheetConfirmTitle(action),
                              confirmKind: action.isDestructive ? .critical : .primary) {
                model.run(action, on: machine)
            }
        }
    }

    /// Consumes `commands.pendingNavigation` at the tab level: only when it names *this*
    /// machine — a request for another one is left for that other sheet (or the split
    /// view's selection change) to apply. Clears it once applied, so a request is never
    /// re-consumed a second time by a later appearance of this same sheet.
    private func applyPendingNavigation() {
        guard let pending = commands.pendingNavigation, pending.machine == machine.name else { return }
        tab = pending.tab
        commands.pendingNavigation = nil
    }

    // MARK: - Actions

    private var busy: Bool { model.inFlight[machine.name] != nil }

    /// The Summary's action bar (FR2): direct actions first, then the destructive ones,
    /// whose ellipsis says a confirmation comes next. All of them disabled while this
    /// machine mutates — reads elsewhere stay live, the kit's lock is never bypassed.
    private var actionBar: some View {
        // Folds into a "…" menu rather than wrapping: at the 900pt minimum the seven labels
        // do not fit, and a wrapped "Désinstallation…" reads as a broken control rather than
        // a narrow one. Each label keeps its own line.
        //
        // No action is ever "active", so the overflow button never takes a selected
        // appearance — unlike the tab bar, it only ever states that actions are hidden.
        OverflowRow(
            items: FleetModel.Action.allCases,
            isActive: { _ in false },
            menuTitle: { Text(verbatim: $0.needsConfirmation ? "\($0.title)…" : $0.title) },
            activate: { action in
                if action.needsConfirmation {
                    pendingAction = action
                } else {
                    model.run(action, on: machine)
                }
            },
            overflowStyle: { _ in PillButtonStyle(kind: .secondary) },
            itemLabel: { actionButton($0) }
        )
        // The menu inherits the same lock the buttons obey: the kit's lock is never bypassed.
        .disabled(busy)
    }

    private func actionButton(_ action: FleetModel.Action) -> some View {
        Button {
            if action.needsConfirmation {
                pendingAction = action
            } else {
                model.run(action, on: machine)
            }
        } label: {
            // The ellipsis says a confirmation comes next — which is now wider than
            // destruction: a restart confirms too. The glyph is typography, not translation
            // material.
            Text(verbatim: action.needsConfirmation ? "\(action.title)…" : action.title)
        }
        .buttonStyle(PillButtonStyle(kind: action.isDestructive ? .destructive : .secondary))
        .disabled(busy)
        .accessibilityLabel(Text(verbatim: action.title))
    }

    private func sheetTitle(_ action: FleetModel.Action) -> LocalizedStringKey {
        switch action {
        case .restart: return "Restart \(machine.name)"
        case .update: return "Update \(machine.name)"
        case .restore: return "Restore \(machine.name)"
        case .remove: return "Remove \(machine.name)"
        case .backup, .doctor, .config: return ""
        }
    }

    private func sheetConsequence(_ action: FleetModel.Action) -> LocalizedStringKey {
        switch action {
        case .update:
            // The CLI names the tag it installs; the sheet does too when it is known.
            if let latest = model.latestTag {
                return "A backup of \(machine.name) is taken first, then \(latest) is installed and its service restarts."
            }
            return "A backup of \(machine.name) is taken first, then the latest release is installed and its service restarts."
        case .restart:
            return "The Homeport service on \(machine.name) stops and starts again, then its health is checked. Whatever it serves is briefly unavailable."
        case .restore: return "The most recent local backup replaces the current config and data of \(machine.name)."
        case .remove: return "Homeport is uninstalled from \(machine.name) — service, app, config and data — after a final backup."
        case .backup, .doctor, .config: return ""
        }
    }

    /// Dedicated `confirm.*` keys, not the action-title ones: the critical button is an
    /// imperative ("Restaurer", "Désinstaller") where the titles are nouns in French.
    private func sheetConfirmTitle(_ action: FleetModel.Action) -> LocalizedStringKey {
        switch action {
        case .restart: return "confirm.restart"
        case .update: return "confirm.update"
        case .restore: return "confirm.restore"
        case .remove: return "confirm.remove"
        case .backup, .doctor, .config: return ""
        }
    }

    // MARK: - Tabs

    /// The tabs that own their own scrolling. Both keep their state in a store held by the
    /// window, not here.
    @ViewBuilder
    private var fullTab: some View {
        switch tab {
        case .logs:
            LogsTabView(model: model, commands: commands,
                        session: logSessions.entry(for: machine.name), machine: machine)
        case .dashboard:
            DashboardTabView(model: model, cache: webCache, machine: machine)
        case .events:
            EventsTabView(model: model, feed: eventFeeds.entry(for: machine.name),
                          store: eventFeeds, machine: machine, selectTab: { tab = $0 })
        // Every case is named on purpose: a future tab that starts filling the sheet must
        // fail visibly here rather than silently render the dashboard's web view.
        case .summary, .metrics, .backups, .shell, .updates:
            EmptyView()
        }
    }

    private var tabBar: some View {
        // A folded tab stays reachable two ways: from this menu, and from its ⌘1–⌘8 shortcut,
        // which the window handles in performKeyEquivalent and never consulted this bar.
        OverflowRow(
            items: MachineTab.allCases,
            isActive: { tab == $0 },
            menuTitle: { Text($0.title) },
            activate: { tab = $0 },
            overflowStyle: { TabPillStyle(selected: $0) },
            itemLabel: { candidate in
                Button { tab = candidate } label: { Text(candidate.title) }
                    .buttonStyle(TabPillStyle(selected: tab == candidate))
                    .focused($focusedTab, equals: candidate)
                    // A selected pill is an ink surface: its ring has to be inverse ink.
                    .focusRing(focusedTab == candidate, cornerRadius: Theme.Rounded.pill,
                               onDark: tab == candidate)
                    // Concatenated rather than interpolated: the shortcut is a literal
                    // key combination, the title a catalog key.
                    .help(Text(candidate.title) + Text(verbatim: " (⌘\(candidate.rawValue))"))
                    .accessibilityLabel(Text(candidate.title))
                    .accessibilityAddTraits(tab == candidate ? [.isSelected] : [])
            }
        )
        .padding(.vertical, Theme.Spacing.hair)
    }

    /// The tabs that scroll inside the sheet's own `ScrollView`. Switched on `tab` rather
    /// than falling through to the summary: a tab whose `pendingMessage` becomes nil without
    /// a case here would render the Summary under its own title, and nothing would fail to
    /// compile.
    @ViewBuilder
    private var content: some View {
        switch tab {
        case .summary:
            summary
        case .metrics:
            MetricsTabView(feed: metrics.entry(for: machine.name), store: metrics,
                           machine: machine, goToUpdates: { tab = .updates })
        case .updates:
            UpdatesTabView(model: model, machine: machine, pendingAction: $pendingAction)
        case .backups, .shell:
            if let pending = tab.pendingMessage {
                EmptyStateView(title: tab.title, message: pending)
            } else {
                let _ = assertionFailure("\(tab) has no pendingMessage and no real content — content(for:) needs a case")
                EmptyView()
            }
        // The three that fill the sheet never reach this branch — `fillsSheet` routes them
        // to `fullTab` — but they are named rather than defaulted, so a tab that stops
        // filling the sheet has to answer this question explicitly.
        case .dashboard, .logs, .events:
            let _ = assertionFailure("\(tab) should have been routed to fullTab by fillsSheet")
            EmptyView()
        }
    }

    // MARK: - Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            if model.statuses[machine.name]?.reachable == false {
                StaleDataNotice(model: model)
            }
            actionBar
            if let report = model.lastError[machine.name] {
                LastActionErrorView(report: report)
            }
            VStack(alignment: .leading, spacing: 0) {
                field("Health") { healthValue }
                field("Version") { versionValue }
                field("Disk") { text(display.status?.diskUsedPercent.map(FleetOverviewView.percent)) }
                field("Uptime") { text(uptime) }
                field("SSH latency") { text(latency) }
                field("Last seen at") {
                    if let seen = display.lastSeen {
                        text(FleetOverviewView.age(seen))
                    } else {
                        Text("Never seen").styled(Theme.data).foregroundStyle(Theme.ink)
                    }
                }
            }
            recentTasks
        }
    }

    // MARK: - Recent tasks

    /// The last ~10 journal entries for this machine (FR6). The journal is filtered on
    /// the inventory name — its exact identifier everywhere.
    private var machineTasks: [HistoryStore.TaskEntry] {
        Array(model.tasks.lazy.filter { $0.machine == machine.name }.prefix(10))
    }

    private var recentTasks: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Recent tasks")
                .styled(Theme.sectionTitle)
                .foregroundStyle(Theme.ink)
            if !model.historyAvailable {
                TaskJournalUnavailableView()
            } else if machineTasks.isEmpty {
                EmptyStateView(
                    title: "No tasks yet",
                    message: "Actions run on this machine from this Mac — app or command line — will appear here.")
            } else {
                DataTable(columns: taskColumns, rows: machineTasks,
                          rowLabel: { taskAnnouncement($0, includeMachine: false) })
            }
        }
    }

    private var taskColumns: [DataColumn<HistoryStore.TaskEntry>] {
        [
            DataColumn("Date", width: 180) { entry in
                TaskDateText(date: entry.startedAt)
            },
            DataColumn("Action") { entry in
                Text(verbatim: entry.action)
                    .styled(Theme.data)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
            },
            DataColumn("Status", width: 90) { entry in
                TaskStatusPill(status: entry.status)
            },
        ]
    }

    @ViewBuilder
    private var healthValue: some View {
        HStack(spacing: Theme.Spacing.xs) {
            StatusPill(severity: severity)
            // The kit decides what is wrong; this view only says it in the user's language.
            ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
                Text(reason)
                    .styled(Theme.body)
                    .foregroundStyle(Theme.ink)
            }
        }
    }

    private var reasons: [LocalizedStringKey] { statusReasons(issues) }

    /// Installed version against the latest release — both machine-produced, both mono.
    @ViewBuilder
    private var versionValue: some View {
        if let installed = display.status?.installedVersion {
            HStack(spacing: Theme.Spacing.xs) {
                Text(verbatim: installed).styled(Theme.data).foregroundStyle(Theme.ink)
                if let latest = issues.availableUpdate {
                    Text(verbatim: "→ \(latest)").styled(Theme.data)
                        .foregroundStyle(Theme.semanticWarning)
                }
            }
        } else {
            Text("Unknown").styled(Theme.data).foregroundStyle(Theme.ink)
        }
    }

    private var uptime: String? {
        display.status?.uptimeSeconds.map {
            Duration.seconds($0).formatted(
                .units(allowed: [.days, .hours, .minutes], width: .abbreviated))
        }
    }

    private var latency: String? {
        display.status?.sshLatencyMs.map { Measurement(value: Double($0), unit: UnitDuration.milliseconds)
            .formatted(.measurement(width: .abbreviated)) }
    }

    // MARK: - Layout helpers

    /// One labelled line of the summary: eyebrow label, value, hairline separator.
    private func field<Content: View>(_ label: LocalizedStringKey,
                                      @ViewBuilder value: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
                Text(label)
                    .styled(Theme.eyebrow)
                    .foregroundStyle(Theme.ink)
                    .textCase(.uppercase)
                    .frame(width: 170, alignment: .leading)
                value()
                Spacer(minLength: 0)
            }
            .padding(.vertical, Theme.Spacing.xs)
            Rectangle().fill(Theme.hairlineSoft).frame(height: Theme.Spacing.hair)
        }
    }

    private func text(_ value: String?) -> some View {
        (value.map { Text(verbatim: $0) } ?? Text("Unknown"))
            .styled(Theme.data)
            .foregroundStyle(Theme.ink)
    }
}
