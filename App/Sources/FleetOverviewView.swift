import SwiftUI
import HomePortKit

/// The global dashboard: one line per declared machine. The rows themselves are built by
/// `fleetRows(...)` in the kit, where the fallback on last-known data is covered by tests —
/// this view only renders them.
struct FleetOverviewView: View {
    @ObservedObject var model: FleetModel
    @ObservedObject var commands: ControlCenterCommands
    let select: (String) -> Void

    @State private var filter = ""
    @FocusState private var filterFocused: Bool

    private var rows: [FleetRow] { model.rows(matching: filter) }

    var body: some View {
        // The history section can outgrow the window, and this view had no ScrollView
        // before it existed — the whole content scrolls now.
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                header
                if model.machines.isEmpty {
                    noFleet
                } else if rows.isEmpty {
                    noMatch
                } else {
                    DataTable(columns: columns, rows: rows,
                              onSelect: { select($0.name) },
                              rowLabel: Self.announcement)
                }
                // No journal noise under onboarding: with no machine declared and no
                // task ever recorded, the section would only crowd the guidance above.
                // An unavailable journal still shows — hiding it here would bury the
                // only visible warning that hpm.db could not be opened.
                if !model.historyAvailable || !(model.machines.isEmpty && model.tasks.isEmpty) {
                    history
                }
            }
        }
        .padding(Theme.Spacing.lg)
        .onChange(of: commands.signal) { signal in
            if signal?.command == .focusFilter { filterFocused = true }
        }
        // ⌘F means something only while this view is the one on screen. The journal can
        // advance from the CLI while this window is closed, so it reloads on appearance
        // instead of waiting for the periodic refresh.
        .onAppear {
            commands.handling(.focusFilter, true)
            model.reloadTasks()
        }
        .onDisappear { commands.handling(.focusFilter, false) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
            Text("Fleet")
                .styled(Theme.windowTitle)
                .foregroundStyle(Theme.ink)
            Spacer(minLength: Theme.Spacing.md)
            filterField
            Button { model.refresh() } label: { Text("Refresh") }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .disabled(model.refreshing)
                .help(Text("Refresh now (⌘R)"))
                .accessibilityLabel(Text("Refresh the fleet"))
        }
    }

    private var filterField: some View {
        TextField(text: $filter) {
            Text("Filter by name")
        }
        .textFieldStyle(.plain)
        .themeFont(Theme.data)
        .foregroundStyle(Theme.ink)
        .focused($filterFocused)
        .frame(width: 200)
        .padding(.vertical, 4)
        .padding(.horizontal, Theme.Spacing.xs)
        .background(Theme.surfaceSoft, in: RoundedRectangle(cornerRadius: Theme.Rounded.md))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Rounded.md)
                .stroke(filterFocused ? Theme.ink : Theme.hairline,
                        lineWidth: filterFocused ? Theme.Metrics.focusRing : 1))
        .help(Text("Filter machines by name (⌘F)"))
        .accessibilityLabel(Text("Filter machines by name"))
    }

    // MARK: - Columns

    private var columns: [DataColumn<FleetRow>] {
        [
            DataColumn("Machine") { row in
                HStack(spacing: Theme.Spacing.xs) {
                    Circle()
                        .fill(Theme.color(of: row.block))
                        .frame(width: Theme.Metrics.blockDot, height: Theme.Metrics.blockDot)
                        .accessibilityHidden(true)
                    // Machine-produced: a name is never translated and always renders mono.
                    Text(verbatim: row.name)
                        .styled(Theme.data)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                }
            },
            DataColumn("Status", width: 90) { row in
                StatusPill(severity: row.severity)
            },
            DataColumn("Version", width: 100) { row in
                value(row.version)
            },
            DataColumn("Disk", width: 55, alignment: .trailing) { row in
                value(row.diskUsedPercent.map(Self.percent))
            },
            DataColumn("Backup", width: 100) { row in
                value(row.lastBackupAt.map(Self.age), unknown: Text("Never"))
            },
            DataColumn("Last seen", width: 90) { row in
                value(row.lastSeen.map(Self.age), unknown: Text("Never seen"))
            },
        ]
    }

    /// A data cell: mono, ink, and an explicit word rather than a blank when unknown.
    private func value(_ text: String?, unknown: Text = Text("Unknown")) -> some View {
        (text.map { Text(verbatim: $0) } ?? unknown)
            .styled(Theme.data)
            .foregroundStyle(Theme.ink)
            .lineLimit(1)
    }

    // MARK: - Formatting

    /// Durations, dates and percentages are shown to a human, so they go through a
    /// localized `FormatStyle` rather than being assembled by hand.
    static func percent(_ used: Int) -> String {
        (Double(used) / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    /// Abbreviated: the column is 100 px wide and every language has to fit in it.
    static func age(_ date: Date) -> String {
        date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }

    /// One announcement per line instead of six loose cells: the machine name first, then
    /// its state, then what is wrong with it — the row's `issues`, in the catalog's words.
    static func announcement(_ row: FleetRow) -> Text {
        var text = Text(verbatim: row.name) + Text(verbatim: ". ") + row.severity.accessibilityText
        for reason in statusReasons(row.issues) {
            text = text + Text(verbatim: ". ") + Text(reason)
        }
        return text
    }

    // MARK: - History

    /// The global journal (FR6): every action initiated from this Mac, app or CLI,
    /// newest first. ~50 lines; the full output of an entry lives in `hpm tasks --id`.
    private var historyRows: [HistoryStore.TaskEntry] { Array(model.tasks.prefix(50)) }

    private var history: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("History")
                .styled(Theme.sectionTitle)
                .foregroundStyle(Theme.ink)
            if !model.historyAvailable {
                TaskJournalUnavailableView()
            } else if historyRows.isEmpty {
                EmptyStateView(
                    title: "No tasks yet",
                    message: "Every action started from this Mac — from the app or from the hpm command line — is recorded here once it runs.")
            } else {
                DataTable(columns: historyColumns, rows: historyRows,
                          rowLabel: { taskAnnouncement($0, includeMachine: true) })
            }
        }
    }

    private var historyColumns: [DataColumn<HistoryStore.TaskEntry>] {
        [
            DataColumn("Date", width: 180) { entry in
                TaskDateText(date: entry.startedAt)
            },
            DataColumn("Machine") { entry in
                value(entry.machine)
            },
            DataColumn("Action", width: 110) { entry in
                value(entry.action)
            },
            DataColumn("Status", width: 90) { entry in
                TaskStatusPill(status: entry.status)
            },
        ]
    }

    // MARK: - Empty states

    private var noFleet: some View {
        EmptyStateView(
            title: "No machines yet",
            message: """
                The control center reads your fleet from this file. Declare a first \
                machine and it shows up here, with its own colour.
                """,
            detail: """
                \(expandPath(FleetStore.defaultPath))

                machines:
                  - name: homeport-01
                    ssh: pi@homeport-01.local

                hpm machine add homeport-01 --ssh pi@homeport-01.local
                """,
            actionTitle: "Reload fleet.yaml",
            action: { model.reloadFleet() })
    }

    private var noMatch: some View {
        EmptyStateView(
            title: "No machine matches",
            message: "Clear the filter to see the whole fleet again.",
            actionTitle: "Clear the filter",
            action: { filter = "" })
    }
}

// MARK: - Task journal cells (shared with MachineDetailView)

/// The localized name of a task status — the pill's label and the VoiceOver
/// announcements speak with the same words.
func taskStatusLabel(_ status: HistoryStore.TaskStatus) -> LocalizedStringKey {
    switch status {
    case .running: return "Running"
    case .success: return "Success"
    case .failure: return "Failure"
    case .interrupted: return "Interrupted"
    }
}

/// One VoiceOver announcement per journal line: the action first, then (in the global
/// history) the machine, then the localized status, then the timestamp. The timestamp is
/// spoken as a formatted date: raw ISO 8601 is machine content *on screen*, but an
/// announcement is speech, and "2026-08-23T10:40:00Z" read letter by letter helps no one.
func taskAnnouncement(_ entry: HistoryStore.TaskEntry, includeMachine: Bool) -> Text {
    var text = Text(verbatim: entry.action)
    if includeMachine {
        text = text + Text(verbatim: ". ") + Text(verbatim: entry.machine)
    }
    return text
        + Text(verbatim: ". ") + Text(taskStatusLabel(entry.status))
        + Text(verbatim: ". ")
        + Text(entry.startedAt, format: .dateTime.year().month().day().hour().minute())
}

/// A task status is an app concept: localized label, semantic colour — and always both,
/// so the state survives without the colour. `interrupted` is written by story 1.3 only,
/// but the journal can already contain it once 1.3 ships, so it renders.
struct TaskStatusPill: View {
    let status: HistoryStore.TaskStatus

    private var label: LocalizedStringKey { taskStatusLabel(status) }

    private var severity: FleetRow.Severity {
        switch status {
        case .success: return .ok
        case .failure: return .critical
        case .running, .interrupted: return .warning
        }
    }

    var body: some View {
        Text(label)
            .styled(Theme.eyebrow)
            .foregroundStyle(Theme.color(of: severity))
            .padding(.vertical, 2)
            .padding(.horizontal, 10)
            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: Theme.Rounded.pill))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Rounded.pill)
                    .stroke(Theme.color(of: severity).opacity(0.25), lineWidth: 1))
            .accessibilityElement()
            .accessibilityLabel(Text(label))
    }
}

/// The truthful empty state when `hpm.db` could not be opened: not "no tasks yet" —
/// actions still run, they just leave no receipt. The state path is machine content.
struct TaskJournalUnavailableView: View {
    var body: some View {
        EmptyStateView(
            title: "Task journal unavailable",
            message: "The task journal could not be opened — actions still run normally, they just leave no trace here. Check the file below, then relaunch the app.",
            detail: expandPath(HistoryStore.defaultPath))
    }
}

/// A journal timestamp is machine content: the ISO 8601 UTC string as stored, mono,
/// never translated.
struct TaskDateText: View {
    let date: Date

    var body: some View {
        Text(verbatim: HistoryStore.iso8601String(from: date))
            .styled(Theme.data)
            .foregroundStyle(Theme.ink)
            .lineLimit(1)
    }
}
