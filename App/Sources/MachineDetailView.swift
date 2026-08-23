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

    /// What is not here yet, and who brings it. Only Dashboard and Logs have a story
    /// number in this epic; the rest arrive with later epics and are not invented one.
    var pendingMessage: LocalizedStringKey? {
        switch self {
        case .summary: return nil
        case .dashboard: return "The machine's Homeport dashboard is embedded here by story 1.4."
        case .logs: return "Centralized logs, continuous follow and text filter arrive with story 1.5."
        case .events: return "The event stream arrives with the Homeport API, in a later epic."
        case .metrics: return "Metric charts arrive with the Homeport API, in a later epic."
        case .backups: return "Backup jobs and restores arrive in a later epic."
        case .shell: return "The embedded terminal arrives in a later epic."
        case .updates: return "Guided updates arrive in a later epic."
        }
    }
}

/// A machine sheet: its coloured banner, the eight tabs, and a populated Summary. The seven
/// other tabs exist, take focus, answer their shortcut and say what will fill them.
struct MachineDetailView: View {
    @ObservedObject var model: FleetModel
    @ObservedObject var commands: ControlCenterCommands
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
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        }
        .onDisappear { commands.handling(.selectTab, false) }
        // The UX-DR6 confirmation. `.sheet`'s native scrim is the dimming; ⌘-shortcuts
        // stay routed by `ControlCenterNSWindow.performKeyEquivalent` while it shows.
        .sheet(item: $pendingAction) { action in
            ConfirmationSheet(title: sheetTitle(action),
                              consequence: sheetConsequence(action),
                              confirmTitle: sheetConfirmTitle(action)) {
                model.run(action, on: machine)
            }
        }
    }

    // MARK: - Actions

    private var busy: Bool { model.inFlight[machine.name] != nil }

    /// The Summary's action bar (FR2): direct actions first, then the destructive ones,
    /// whose ellipsis says a confirmation comes next. All of them disabled while this
    /// machine mutates — reads elsewhere stay live, the kit's lock is never bypassed.
    private var actionBar: some View {
        HStack(spacing: Theme.Spacing.xs) {
            ForEach(FleetModel.Action.allCases) { action in
                actionButton(action)
            }
        }
    }

    private func actionButton(_ action: FleetModel.Action) -> some View {
        Button {
            if action.isDestructive {
                pendingAction = action
            } else {
                model.run(action, on: machine)
            }
        } label: {
            // The ellipsis is typography, not translation material.
            Text(verbatim: action.isDestructive ? "\(action.title)…" : action.title)
        }
        .buttonStyle(PillButtonStyle(kind: action.isDestructive ? .destructive : .secondary))
        .disabled(busy)
        .accessibilityLabel(Text(verbatim: action.title))
    }

    private func sheetTitle(_ action: FleetModel.Action) -> LocalizedStringKey {
        switch action {
        case .update: return "Update \(machine.name)"
        case .restore: return "Restore \(machine.name)"
        case .remove: return "Remove \(machine.name)"
        case .backup, .restart, .doctor, .config: return ""
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
        case .restore: return "The most recent local backup replaces the current config and data of \(machine.name)."
        case .remove: return "Homeport is uninstalled from \(machine.name) — service, app, config and data — after a final backup."
        case .backup, .restart, .doctor, .config: return ""
        }
    }

    /// Dedicated `confirm.*` keys, not the action-title ones: the critical button is an
    /// imperative ("Restaurer", "Désinstaller") where the titles are nouns in French.
    private func sheetConfirmTitle(_ action: FleetModel.Action) -> LocalizedStringKey {
        switch action {
        case .update: return "confirm.update"
        case .restore: return "confirm.restore"
        case .remove: return "confirm.remove"
        case .backup, .restart, .doctor, .config: return ""
        }
    }

    // MARK: - Tabs

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.xs) {
                ForEach(MachineTab.allCases) { candidate in
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
            }
            .padding(.vertical, Theme.Spacing.hair)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let pending = tab.pendingMessage {
            EmptyStateView(title: tab.title, message: pending)
        } else {
            summary
        }
    }

    // MARK: - Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            if model.statuses[machine.name]?.reachable == false {
                unreachableNotice
            }
            actionBar
            if let report = model.lastError[machine.name] {
                lastActionError(report)
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

    /// A last action's persistent focus (a toast would vanish): the fact in the app's
    /// words, the remedy being the report text itself — machine content, mono, selectable.
    /// The headline follows the report's kind: a doctor that succeeded while finding
    /// failing checks must not be announced as a failed action.
    private func lastActionError(_ report: FleetModel.LastReport) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(report.kind == .failure ? "Last action failed" : "Last action reported problems")
                .styled(Theme.bodyStrong)
                .foregroundStyle(report.kind == .failure ? Theme.semanticCritical : Theme.semanticWarning)
            Text(verbatim: report.message)
                .styled(Theme.data)
                .foregroundStyle(Theme.ink)
                .lineSpacing(Theme.data.lineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.md)
        .background(Theme.surfaceSoft, in: RoundedRectangle(cornerRadius: Theme.Rounded.md))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Rounded.md)
                .stroke((report.kind == .failure ? Theme.semanticCritical : Theme.semanticWarning).opacity(0.25), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    /// The unreachable case is guiding, never an error page: the sheet keeps the last known
    /// values and offers the retry.
    private var unreachableNotice: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text("Unreachable — showing the last known data.")
                .styled(Theme.body)
                .foregroundStyle(Theme.ink)
                .lineSpacing(Theme.body.lineSpacing)
            Button { model.refresh() } label: { Text("Retry") }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .disabled(model.refreshing)
                .accessibilityLabel(Text("Retry reaching the machine"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.md)
        .background(Theme.surfaceSoft, in: RoundedRectangle(cornerRadius: Theme.Rounded.md))
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
