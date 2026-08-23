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
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.lg)
        .onChange(of: commands.signal) { signal in
            if signal?.command == .focusFilter { filterFocused = true }
        }
        // ⌘F means something only while this view is the one on screen.
        .onAppear { commands.handling(.focusFilter, true) }
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
