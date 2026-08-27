import SwiftUI
import HomePortKit

// The reusable surface of the design system. Stories 1.3, 1.4 and 1.5 consume these
// components; none of them redefines a token — every value below comes from `Theme`.

// MARK: - Focus

extension View {
    /// A custom `ButtonStyle` suppresses the system focus ring, and the accessibility floor
    /// requires focus to stay visible — so the ring is drawn explicitly.
    ///
    /// `onDark` is not decoration: selection in this app is an ink-black surface, and focus
    /// lands on the selected row more often than anywhere else. A ring in ink on an ink
    /// ground is no ring at all, so over an inverse surface it is drawn in inverse ink.
    func focusRing(_ visible: Bool, cornerRadius: CGFloat, onDark: Bool = false) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(onDark ? Theme.inverseInk : Theme.ink,
                        lineWidth: visible ? Theme.Metrics.focusRing : 0))
    }
}

// MARK: - Status pill

extension FleetRow.Severity {
    /// The pill's own words: state is carried by colour *and* label, everywhere.
    /// Namespaced keys rather than their own English text: "OK" is also what a macOS alert
    /// calls its confirmation button, and the two need different words in zh-Hans (正常 for a
    /// state, 确定 for a button). One key cannot carry both.
    var label: LocalizedStringKey {
        switch self {
        case .ok: return "status.pill.ok"
        case .warning: return "status.pill.warning"
        case .critical: return "status.pill.critical"
        }
    }

    /// Spelled out for VoiceOver, where the eyebrow abbreviation reads poorly.
    var accessibilityText: Text {
        switch self {
        case .ok: return Text("Status: healthy")
        case .warning: return Text("Status: needs attention")
        case .critical: return Text("Status: critical")
        }
    }
}

/// The kit's issues, in the catalog's words — a pure projection and nothing else.
///
/// The rule that decides *what* is wrong lives once, in `machineIssues`, where `swift test`
/// covers it. What is left here is the part a kit free of SwiftUI cannot do: turn a fact
/// into a translated sentence, because `machineWarnings` speaks the CLI's English and the
/// CLI owns those strings.
func statusReasons(_ issues: [MachineIssue]) -> [LocalizedStringKey] {
    issues.map(\.label)
}

extension MachineIssue {
    var label: LocalizedStringKey {
        switch self {
        case .notPolled: return "Not polled yet"
        case .unreachable: return "Unreachable"
        case .serviceInactive: return "Service inactive"
        case .healthzFailing: return "Health check failing"
        case .diskAlmostFull: return "Disk almost full"
        case .updateAvailable: return "Update available"
        }
    }

    /// The release this machine could move to, when that is what the issue is about.
    var availableUpdate: String? {
        if case .updateAvailable(let latest) = self { return latest }
        return nil
    }
}

extension Array where Element == MachineIssue {
    /// The release the machine could move to, or `nil` when no update is pending.
    var availableUpdate: String? { compactMap(\.availableUpdate).first }
}

/// State at a glance: canvas ground, semantic text, and always a *label* next to the
/// colour so the state survives without it. Carries its own VoiceOver announcement.
struct StatusPill: View {
    let severity: FleetRow.Severity

    var body: some View {
        Text(severity.label)
            .styled(Theme.eyebrow)
            .foregroundStyle(Theme.color(of: severity))
            .padding(.vertical, 2)
            .padding(.horizontal, 10)
            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: Theme.Rounded.pill))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Rounded.pill)
                    .stroke(Theme.color(of: severity).opacity(0.25), lineWidth: 1))
            .accessibilityElement()
            .accessibilityLabel(severity.accessibilityText)
    }
}

// MARK: - Buttons and tabs

/// The only button shape in the app. Destructive stays on canvas here; `critical` — the
/// app's single red ground — belongs to the confirmation sheet and nowhere else.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive, critical }
    var kind: Kind = .secondary

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .themeFont(Theme.button)
            .foregroundStyle(foreground)
            .padding(.vertical, 6)
            .padding(.horizontal, Theme.Spacing.md)
            .background(background, in: RoundedRectangle(cornerRadius: Theme.Rounded.pill))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Rounded.pill)
                    .stroke(filled ? Color.clear : Theme.hairline, lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Rounded.pill))
    }

    private var filled: Bool { kind == .primary || kind == .critical }

    private var foreground: Color {
        switch kind {
        case .primary, .critical: return Theme.onPrimary
        case .secondary: return Theme.ink
        case .destructive: return Theme.semanticCritical
        }
    }

    private var background: Color {
        switch kind {
        case .primary: return Theme.ink
        case .critical: return Theme.semanticCritical
        case .secondary, .destructive: return Theme.canvas
        }
    }
}

/// Selection is a primary black surface — the same pattern as the sidebar.
struct TabPillStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .themeFont(Theme.button)
            .foregroundStyle(selected ? Theme.onPrimary : Theme.ink)
            .padding(.vertical, 5)
            .padding(.horizontal, 14)
            .background(selected ? Theme.ink : Theme.canvas,
                        in: RoundedRectangle(cornerRadius: Theme.Rounded.pill))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Rounded.pill)
                    .stroke(selected ? Color.clear : Theme.hairline, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Rounded.pill))
    }
}

// MARK: - Filter field

/// The soft-surfaced text field that filters a list, focused by ⌘F.
///
/// Extracted from `FleetOverviewView` (story 1.1) and `LogsTabView` (story 1.5), which
/// carried ten byte-identical modifier lines apiece — finding **D-1** of the epic 1
/// retrospective, and the reason `docs/build/design-components.md` now exists.
///
/// `focus` is the caller's own `@FocusState` rather than one owned here: ⌘F arrives from
/// outside the field (a window-level signal the host view watches), so the state has to
/// live where that signal lands.
struct FilterField: View {
    @Binding var text: String
    /// The visible placeholder.
    let prompt: LocalizedStringKey
    /// Kept distinct from `prompt`: the fleet field shows the short "Filter by name" but
    /// announces the unambiguous "Filter machines by name". Folding them would change the
    /// visible text and orphan a catalog key.
    let accessibility: LocalizedStringKey
    /// The tooltip, which names the shortcut. Kept a parameter rather than composed from
    /// `prompt`: each call site owns its own catalog key, and folding them into one
    /// concatenation would drop two localized keys from the catalogue.
    let hint: LocalizedStringKey
    let focus: FocusState<Bool>.Binding

    var body: some View {
        TextField(text: $text) {
            Text(prompt)
        }
        .textFieldStyle(.plain)
        .themeFont(Theme.data)
        .foregroundStyle(Theme.ink)
        .focused(focus)
        .frame(width: 200)
        .padding(.vertical, 4)
        .padding(.horizontal, Theme.Spacing.xs)
        .background(Theme.surfaceSoft, in: RoundedRectangle(cornerRadius: Theme.Rounded.md))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Rounded.md)
                .stroke(focus.wrappedValue ? Theme.ink : Theme.hairline,
                        lineWidth: focus.wrappedValue ? Theme.Metrics.focusRing : 1))
        .help(Text(hint))
        .accessibilityLabel(Text(accessibility))
    }
}

// MARK: - Overflow row

/// A horizontal row that keeps every item on one line: what fits stays visible, the rest
/// folds into a trailing "…" menu.
///
/// Replaces the horizontal `ScrollView` the tab bar and the action bar used to be. That
/// scroll never truncated anything — the content was reachable — but `showsIndicators: false`
/// left nothing to say so, and at the window's nominal 1040pt width the last pill sat flush
/// against the edge, reading as a broken control. A menu states the overflow instead of
/// hiding it.
///
/// The candidates are enumerated rather than generated: a `ForEach` inside `ViewThatFits`
/// collapses to a single candidate, and its ten-subview ceiling covers both call sites
/// (eight tabs, seven actions). `ViewThatFits` takes the first that fits, so the widest
/// split is listed first. Splits wider than `items.count` render identically to the full
/// row, which is harmless.
///
/// The overflow button carries the *style* of a selected item when a folded item is the
/// active one — otherwise a tab selected from the menu would leave the bar showing no
/// selection at all, which is worse than the overflow it replaced. `.menuStyle(.button)`
/// lets the caller's own `ButtonStyle` apply, so no pill metric is duplicated here.
struct OverflowRow<Item: Identifiable, ItemLabel: View, OverflowStyle: ButtonStyle>: View {
    let items: [Item]
    var spacing: CGFloat = Theme.Spacing.xs
    /// Drives both the menu checkmark and the overflow button's selected appearance.
    let isActive: (Item) -> Bool
    let menuTitle: (Item) -> Text
    let activate: (Item) -> Void
    /// Receives `true` when a folded item is the active one.
    let overflowStyle: (Bool) -> OverflowStyle
    @ViewBuilder let itemLabel: (Item) -> ItemLabel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            split(9)
            split(8)
            split(7)
            split(6)
            split(5)
            split(4)
            split(3)
            split(2)
            split(1)
            split(0)
        }
    }

    private func split(_ visible: Int) -> some View {
        let shown = Array(items.prefix(visible))
        let folded = Array(items.dropFirst(visible))
        return HStack(spacing: spacing) {
            ForEach(shown) { item in
                itemLabel(item).fixedSize()
            }
            if !folded.isEmpty {
                Menu {
                    ForEach(folded) { item in
                        Button { activate(item) } label: {
                            if isActive(item) {
                                Label { menuTitle(item) } icon: { Image(systemName: "checkmark") }
                            } else {
                                menuTitle(item)
                            }
                        }
                    }
                } label: {
                    // The ellipsis is typography, not translation material — the same
                    // reasoning as the destructive action titles.
                    Text(verbatim: "…")
                }
                .menuStyle(.button)
                .buttonStyle(overflowStyle(folded.contains(where: isActive)))
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(Text("overflow.more"))
            }
        }
    }
}

// MARK: - Sidebar

struct SidebarRow: View {
    let title: String
    /// `nil` for the fleet entry, which has no machine identity.
    let block: MachineBlock?
    let severity: FleetRow.Severity?
    let selected: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if let block {
                Circle()
                    .fill(Theme.color(of: block))
                    .frame(width: Theme.Metrics.blockDot, height: Theme.Metrics.blockDot)
            }
            Text(verbatim: title)
                .styled(selected ? Theme.bodyStrong : Theme.body)
                .foregroundStyle(selected ? Theme.onPrimary : Theme.ink)
                .lineLimit(1)
            Spacer(minLength: Theme.Spacing.xxs)
            if let severity {
                Circle()
                    .fill(Theme.color(of: severity))
                    .frame(width: Theme.Metrics.blockDot, height: Theme.Metrics.blockDot)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .frame(height: Theme.Metrics.sidebarRowHeight)
        .background(selected ? Theme.ink : Theme.canvas,
                    in: RoundedRectangle(cornerRadius: Theme.Rounded.sm))
        .contentShape(RoundedRectangle(cornerRadius: Theme.Rounded.sm))
    }
}

// MARK: - Machine banner

/// The one flat colour field of a machine sheet: its own pastel block, never a state.
struct MachineBanner: View {
    let name: String
    let host: String
    let block: MachineBlock
    let severity: FleetRow.Severity
    /// The in-flight mutation's "… in progress" line; nil when the machine is idle.
    var activity: LocalizedStringKey? = nil

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(verbatim: name)
                    .styled(Theme.windowTitle)
                    .foregroundStyle(Theme.ink)
                    // `styled` carries face and tracking but not the token's line height, so
                    // a 22pt light title gets a frame shorter than its own ascender and is
                    // clipped along the top. Let it keep its natural height.
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: host)
                    .styled(Theme.data)
                    .foregroundStyle(Theme.ink)
            }
            Spacer(minLength: Theme.Spacing.md)
            if let activity {
                HStack(spacing: Theme.Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text(activity)
                        .styled(Theme.body)
                        .foregroundStyle(Theme.ink)
                }
                .accessibilityElement(children: .combine)
            }
            StatusPill(severity: severity)
        }
        .padding(.vertical, Theme.Spacing.md)
        .padding(.horizontal, Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.color(of: block),
                    in: RoundedRectangle(cornerRadius: Theme.Rounded.lg))
    }
}

// MARK: - Confirmation sheet

/// The UX-DR6 destructive confirmation, presented with `.sheet` (whose native scrim is
/// the dimming): a verb title, the consequence in one sentence — both repeating the
/// machine's name — Cancel, and the app's only critical-ground button.
struct ConfirmationSheet: View {
    let title: LocalizedStringKey
    let consequence: LocalizedStringKey
    let confirmTitle: LocalizedStringKey
    /// `.critical` for a destructive action — UX-DR6 makes this the only red ground in the
    /// app. An action that merely interrupts (a restart) confirms with an ordinary pill:
    /// widening the confirmation must not widen the red.
    var confirmKind: PillButtonStyle.Kind = .critical
    let confirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text(title)
                .styled(Theme.sectionTitle)
                .foregroundStyle(Theme.ink)
            Text(consequence)
                .styled(Theme.body)
                .foregroundStyle(Theme.ink)
                .lineSpacing(Theme.body.lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Spacing.sm) {
                Spacer(minLength: 0)
                Button { dismiss() } label: { Text("Cancel") }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                // Deliberately no `.defaultAction`: Return must never confirm a
                // destructive action by reflex — Escape cancels, destroying takes a click.
                Button { dismiss(); confirm() } label: { Text(confirmTitle) }
                    .buttonStyle(PillButtonStyle(kind: confirmKind))
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 420, alignment: .leading)
        .background(Theme.canvas)
    }
}

// MARK: - Toast

/// The DESIGN.md toast token: inverse ground and ink, `Rounded.md`, transient, bottom
/// right. It confirms in the past tense; failures never toast — they get a persistent
/// focus in the machine sheet instead.
struct ToastView: View {
    /// Machine content, rendered mono and never translated.
    let machine: String
    let message: LocalizedStringKey

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text(verbatim: machine)
                .styled(Theme.data)
                .foregroundStyle(Theme.inverseInk)
            Text(message)
                .styled(Theme.body)
                .foregroundStyle(Theme.inverseInk)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .padding(.horizontal, Theme.Spacing.md)
        .background(Theme.inverseCanvas, in: RoundedRectangle(cornerRadius: Theme.Rounded.md))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Last action report

/// A last action's persistent focus (a toast would vanish): the fact in the app's words,
/// the remedy being the report text itself — machine content, mono, selectable. The
/// headline follows the report's kind: a doctor that succeeded while finding failing checks
/// must not be announced as a failed action.
///
/// Shared by every tab that can trigger `FleetModel.run` (Summary, Updates, …): a failure
/// must surface the same way wherever it was triggered from, not just on Summary — one box,
/// not one drifting copy per tab.
struct LastActionErrorView: View {
    let report: FleetModel.LastReport

    var body: some View {
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
}

// MARK: - Stale data notice

/// The unreachable case is guiding, never an error page: whichever tab shows it keeps the
/// last known values on screen and offers the retry, rather than blanking out.
///
/// Shared by every tab that renders data through `FleetModel.displayStatus(for:)` (Summary,
/// Updates, …): the wording and the `refreshing` guard on Retry must not drift tab to tab.
struct StaleDataNotice: View {
    @ObservedObject var model: FleetModel

    var body: some View {
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
}

// MARK: - Data table

struct DataColumn<Row>: Identifiable {
    /// The untranslated title. A column's identity has to survive a redraw — a `UUID()` in a
    /// computed property hands `ForEach` a brand new identity every time the table is
    /// rebuilt, which throws away the cells and the keyboard focus sitting in them.
    let id: String
    let title: LocalizedStringKey
    let width: CGFloat?
    let alignment: Alignment
    let cell: (Row) -> AnyView

    /// The title is taken as a `String` so the same value can be both the stable id and the
    /// catalog key; `Localizable.xcstrings` is hand-maintained (`extractionState: manual`),
    /// so the key still has to appear there under exactly this text.
    init<Content: View>(_ title: String,
                        width: CGFloat? = nil,
                        alignment: Alignment = .leading,
                        @ViewBuilder cell: @escaping (Row) -> Content) {
        self.id = title
        self.title = LocalizedStringKey(title)
        self.width = width
        self.alignment = alignment
        self.cell = { AnyView(cell($0)) }
    }
}

/// Mono, tabular, eyebrow headers, 26 px rows separated by hairline-soft.
///
/// When `onSelect` is given, a line is a real button: it takes keyboard focus, answers Space
/// and Return, shows the focus ring, and announces itself to VoiceOver as one element rather
/// than as a handful of loose cells — `rowLabel` is what that one element says.
struct DataTable<Row: Identifiable>: View {
    let columns: [DataColumn<Row>]
    let rows: [Row]
    var onSelect: ((Row) -> Void)?
    var rowLabel: ((Row) -> Text)?

    @FocusState private var focusedRow: Row.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Rectangle()
                        .fill(Theme.hairlineSoft)
                        .frame(height: Theme.Spacing.hair)
                }
                line(row)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: Theme.Rounded.md))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Rounded.md)
                .stroke(Theme.hairline, lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ForEach(columns) { column in
                sized(column) {
                    Text(column.title)
                        .styled(Theme.eyebrow)
                        .foregroundStyle(Theme.ink)
                        .textCase(.uppercase)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .frame(height: Theme.Metrics.tableRowHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: Theme.Spacing.hair)
        }
    }

    @ViewBuilder
    private func line(_ row: Row) -> some View {
        if let onSelect {
            let button = Button { onSelect(row) } label: { cells(row) }
                .buttonStyle(.plain)
                .focusable()
                .focused($focusedRow, equals: row.id)
                .focusRing(focusedRow == row.id, cornerRadius: Theme.Rounded.sm)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
            // Without a label the combined element still announces its cells in order; with
            // one, the row leads with what identifies it. An empty label would mute it.
            if let rowLabel {
                button.accessibilityLabel(rowLabel(row))
            } else {
                button
            }
        } else if let rowLabel {
            // A non-selectable row still announces as one element when it has a label,
            // instead of a handful of loose cells.
            cells(row)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(rowLabel(row))
        } else {
            cells(row)
        }
    }

    private func cells(_ row: Row) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            ForEach(columns) { column in
                sized(column) { column.cell(row) }
            }
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .frame(height: Theme.Metrics.tableRowHeight)
        .contentShape(Rectangle())
    }

    /// A column is either pinned to a width or takes what is left; no single `frame`
    /// expresses both, so the branch is explicit.
    @ViewBuilder
    private func sized<Content: View>(_ column: DataColumn<Row>,
                                      @ViewBuilder content: () -> Content) -> some View {
        if let width = column.width {
            content().frame(width: width, alignment: column.alignment)
        } else {
            content().frame(maxWidth: .infinity, alignment: column.alignment)
        }
    }
}

// MARK: - Empty state

/// Written per tab: says what is missing and what to do about it. The one place the
/// pastel voice is allowed to smile.
struct EmptyStateView: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var detail: String?
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title)
                .styled(Theme.sectionTitle)
                .foregroundStyle(Theme.ink)
            Text(message)
                .styled(Theme.body)
                .foregroundStyle(Theme.ink)
                .lineSpacing(Theme.body.lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(verbatim: detail)
                    .styled(Theme.data)
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(Theme.data.lineSpacing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                Button(action: action) { Text(actionTitle) }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .padding(.top, Theme.Spacing.xxs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.xl)
        .background(Theme.surfaceSoft, in: RoundedRectangle(cornerRadius: Theme.Rounded.lg))
    }
}
