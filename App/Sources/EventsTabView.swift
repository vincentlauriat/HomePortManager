import SwiftUI
import HomePortKit

/// One event feed per machine, owned by the window's root view for the same reason
/// `DashboardWebCache` and `LogSessionStore` are: `MachineDetailView` carries
/// `.id(machine.name)` and is recreated on every machine switch, and the tab view itself is
/// recreated on every tab switch. The window a machine was unreachable in must still show
/// its last known events when the user comes back to it (UX-DR5), and a sheet-local
/// `@State` cannot survive either recreation.
@MainActor
final class EventFeedStore: ObservableObject {
    private var feeds: [String: EventFeed] = [:]
    /// One client for the whole app: it owns a `URLSession`, and a per-view one would open
    /// a fresh connection pool on every tab switch.
    private let api = HomeportAPIClient()

    func entry(for name: String) -> EventFeed {
        if let existing = feeds[name] { return existing }
        let feed = EventFeed()
        feeds[name] = feed
        return feed
    }

    /// The reader both surfaces share (AD-13). `cursors` comes from the model's store, so
    /// a broken hpm.db degrades the reset detection and nothing else.
    func reader(cursors: EventCursorStore?) -> HomeportEventsReader {
        HomeportEventsReader(api: api, cursors: cursors)
    }

    /// A machine removed from fleet.yaml must not keep a feed behind the scenes.
    func prune(keeping names: [String]) {
        feeds = feeds.filter { names.contains($0.key) }
    }
}

/// What one machine's Events tab shows, kept out of the view so it survives it.
@MainActor
final class EventFeed: ObservableObject {
    /// Oldest first, the contract's own order (§6). The table reverses at the point of
    /// display; the stored order stays the one the cursor advances along.
    @Published private(set) var events: [HomeportEvent] = []
    /// Non-nil when this machine's Homeport does not serve the surface — the state that
    /// points at Updates. Mutually exclusive with `unreachable` by construction.
    @Published private(set) var unavailable: APIUnavailableReason?
    /// Non-nil when the machine did not answer. The events already read stay on screen.
    @Published private(set) var unreachable: String?
    /// When this feed last got an answer — its own reading, deliberately kept apart from
    /// `FleetModel.lastSeenAt`, which is the ssh poll's. The two channels can disagree
    /// (ssh up, HTTP down) and merging them would make each lie about the other.
    @Published private(set) var lastReachedAt: Date?
    /// A first read is in flight and nothing is on screen yet.
    @Published private(set) var loading = false
    /// The last read found the history in a new generation and started over (§5). Shown as
    /// a note, never as an error.
    @Published private(set) var historyRestarted = false

    /// False until a full window has landed — what makes the first read a `.window` and
    /// every later one an increment from the cursor.
    private var hasWindow = false

    /// Guards against the manual `retry()` button and the tab's own poll loop landing at
    /// the same time: without it, whichever of the two answers *last* would win even when
    /// it started first, applying a stale result over a fresher one.
    private var isFetching = false

    func read(machine: Machine, through reader: HomeportEventsReader) async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }
        loading = events.isEmpty && unavailable == nil
        let outcome = await reader.read(machine,
                                        mode: hasWindow ? .sinceCursor : .window,
                                        limit: HomeportEventsReader.defaultLimit,
                                        // The app is the cursor's only writer: `hpm events`
                                        // reads without moving it, so nothing else can
                                        // advance past what this feed has yet to show.
                                        advancingCursor: true)
        // A cancelled fetch (the view went away mid-read) is not an answer from the
        // machine: nothing published here may change because of it.
        if case .cancelled = outcome { return }
        loading = false
        apply(outcome)
    }

    private func apply(_ outcome: EventsRead) {
        switch outcome {
        case .cancelled:
            return
        case .unavailable(let reason):
            // Not a failure and not a machine with no events: this Homeport has no event
            // journal to show at all, so keeping a stale list would be a lie.
            unavailable = reason
            unreachable = nil
            historyRestarted = false
            events = []
            hasWindow = false
        case .unreachable(let detail):
            // UX-DR5: the last known events stay, with the hour they were last read. The
            // "not available" verdict is dropped, though — it was an observation, and the
            // fresher one is that the machine is not answering. Leaving it up would send
            // the user to Updates for a machine no update can currently reach.
            unreachable = detail
            unavailable = nil
            // The generation note belongs to a read that happened; an outage must not
            // leave it standing over data it no longer describes.
            historyRestarted = false
        case .window(let window):
            unavailable = nil
            unreachable = nil
            lastReachedAt = Date()
            historyRestarted = window.cursorWasReset
            if window.isFullWindow {
                events = window.events
            } else {
                // An increment. Merged by id rather than appended blind: a page can
                // legitimately repeat what is already here after a retry.
                let known = Set(events.map(\.id))
                let merged = (events + window.events.filter { !known.contains($0.id) })
                    .sorted { $0.id < $1.id }
                events = Array(merged.suffix(HomeportEventsReader.defaultLimit))
            }
            hasWindow = true
        }
    }
}

/// The severity segments. `all` is a segment and not an absence: it is what `hpm events`
/// with no `--severity` means, and AD-13 needs the two surfaces to have the same states.
enum EventSeverityFilter: String, CaseIterable, Identifiable, Hashable {
    case all, info, warning, critical

    var id: String { rawValue }

    /// nil is "every severity" — the kit's filter reads it exactly that way.
    var severity: EventSeverity? {
        switch self {
        case .all: return nil
        case .info: return .info
        case .warning: return .warning
        case .critical: return .critical
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .all: return "events.filter.all"
        case .info: return "events.filter.info"
        case .warning: return "events.filter.warning"
        case .critical: return "events.filter.critical"
        }
    }
}

/// The Events tab: the three states of the contract, a severity picker, and the machine's
/// events with their severity in the app's one pill.
struct EventsTabView: View {
    @ObservedObject var model: FleetModel
    @ObservedObject var feed: EventFeed
    let store: EventFeedStore
    let machine: Machine
    /// How the "not available" state hands the user over to Updates (UX-DR5).
    let selectTab: (MachineTab) -> Void

    /// Kept in the view, not the feed: this is a display preference, and it must not
    /// survive into another machine's tab.
    @State private var filter: EventSeverityFilter = .all

    /// 45 s, inside the 30–60 s the epic fixes. Scoped to this view: `.task` starts when
    /// the tab appears and is cancelled when it goes away, so there is no timer to own and
    /// nothing polls while the tab is closed. A background poll, if notifications turn out
    /// to need one, is story 2.2b's decision to make.
    private static let pollInterval: Duration = .seconds(45)

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            filterBar
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: machine.name) {
            let reader = store.reader(cursors: model.eventCursors)
            await feed.read(machine: machine, through: reader)
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                if Task.isCancelled { break }
                await feed.read(machine: machine, through: reader)
            }
        }
    }

    // MARK: Filter

    private var visible: [HomeportEvent] {
        // Reversed at the point of display only: newest first reads better in a table, and
        // `hpm events` reverses in exactly the same place for exactly the same reason.
        feed.events.filtered(severity: filter.severity).reversed()
    }

    private var filterBar: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Picker(selection: $filter) {
                ForEach(EventSeverityFilter.allCases) { option in
                    Text(option.title).tag(option)
                }
            } label: {
                Text("events.column.severity")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // No fixed width: the four labels are translated, and "Avertissement" does not
            // fit an English-sized segment. A segmented picker sizes to its content.
            .fixedSize()
            .accessibilityLabel(Text("Filter events by severity"))
            if feed.loading {
                ProgressView().controlSize(.small)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: The three states of the contract

    @ViewBuilder
    private var content: some View {
        // A first read in flight, nothing on screen yet: never let the empty state claim
        // a confirmed-empty history before the read that would confirm it has returned.
        if feed.loading, feed.events.isEmpty {
            loadingState
        } else if let reason = feed.unavailable {
            unavailableState(reason)
        } else if feed.unreachable != nil, feed.events.isEmpty {
            EmptyStateView(
                title: "Unreachable",
                message: "\(machine.name) is unreachable. Check Tailscale or retry.",
                detail: feed.unreachable,
                actionTitle: "Retry", action: retry)
        } else if feed.events.isEmpty {
            if feed.historyRestarted {
                // A reset that landed on a new, still-empty epoch is not "nothing was
                // ever reported" — the reprise note must survive even when the window
                // it describes is empty.
                EmptyStateView(
                    title: "No events yet",
                    message: "The event history of this machine started a new generation — it is shown from the beginning.")
            } else {
                EmptyStateView(
                    title: "No events yet",
                    message: "This machine has not reported anything yet. Events appear here as its Homeport records them.")
            }
        } else {
            eventList
        }
    }

    private var loadingState: some View {
        HStack(spacing: Theme.Spacing.xs) {
            ProgressView().controlSize(.small)
            Text("Loading…")
                .styled(Theme.body)
                .foregroundStyle(Theme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.xl)
        .background(Theme.surfaceSoft, in: RoundedRectangle(cornerRadius: Theme.Rounded.lg))
    }

    /// UX-DR5's "does not know how to yet" state: warm, explanatory, and pointing at the
    /// one thing that fixes it. Never a red pill, never the word error — an update is the
    /// remedy, an intervention on the machine is not.
    private func unavailableState(_ reason: APIUnavailableReason) -> some View {
        EmptyStateView(
            title: "Events not available",
            message: "This version of Homeport does not serve events yet.",
            detail: detail(for: reason),
            actionTitle: "Go to Updates", action: { selectTab(.updates) })
    }

    /// The version met, when there is one to name (§8, row 2). Machine content: shown as
    /// produced, never translated.
    private func detail(for reason: APIUnavailableReason) -> String? {
        switch reason {
        case .notServed:
            return nil
        case .incompatibleContract(let compatibility):
            return "API contract \(compatibility.describedVersion) — hpm consumes \(HomeportAPIContract.supportedRange)"
        case .surfaceNotServed(let surface):
            return "the API is served, but not its '\(surface)' surface"
        }
    }

    // MARK: The list

    private var eventList: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if feed.unreachable != nil {
                unreachableNotice
            }
            if feed.historyRestarted {
                Text("The event history of this machine started a new generation — it is shown from the beginning.")
                    .styled(Theme.body)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if visible.isEmpty {
                EmptyStateView(
                    title: "No event matches",
                    message: "No event of this machine matches the selected severity.")
            } else {
                ScrollView {
                    DataTable(columns: columns, rows: visible, rowLabel: announcement)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// UX-DR5 again: unreachable keeps the data and says when it was last read, rather
    /// than blanking the tab.
    private var unreachableNotice: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text("Unreachable — showing the last known data.")
                .styled(Theme.body)
                .foregroundStyle(Theme.ink)
            if let seen = feed.lastReachedAt {
                Text("Last seen at")
                    .styled(Theme.eyebrow)
                    .foregroundStyle(Theme.ink)
                    .textCase(.uppercase)
                Text(verbatim: seen.formatted(date: .omitted, time: .shortened))
                    .styled(Theme.data)
                    .foregroundStyle(Theme.ink)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceSoft, in: RoundedRectangle(cornerRadius: Theme.Rounded.md))
    }

    private var columns: [DataColumn<HomeportEvent>] {
        [
            DataColumn("Date", width: 180) { TaskDateText(date: $0.timestamp) },
            // The severity goes through the app's one pill, on the mapped display
            // severity: `info` reads as ok, and no second pill component exists.
            DataColumn("events.column.severity", width: 90) { StatusPill(severity: $0.severity.displaySeverity) },
            DataColumn("events.column.kind", width: 150) { mono($0.kind) },
            DataColumn("events.column.subject", width: 170) { mono($0.subject) },
            DataColumn("events.column.detail") { mono($0.detail ?? "—") },
        ]
    }

    /// Machine content everywhere: a `kind` is served as-is and displayed as-is, an
    /// unknown one included (§6 forbids making the display depend on recognising it).
    private func mono(_ value: String) -> some View {
        Text(verbatim: value)
            .styled(Theme.data)
            .foregroundStyle(Theme.ink)
            .lineLimit(1)
    }

    /// One announcement per line rather than five loose cells.
    private func announcement(_ event: HomeportEvent) -> Text {
        var text = event.severity.displaySeverity.accessibilityText
        text = text + Text(verbatim: ". \(event.kind). \(event.subject)")
        if let detail = event.detail { text = text + Text(verbatim: ". \(detail)") }
        return text
    }

    private func retry() {
        Task {
            await feed.read(machine: machine, through: store.reader(cursors: model.eventCursors))
        }
    }
}
