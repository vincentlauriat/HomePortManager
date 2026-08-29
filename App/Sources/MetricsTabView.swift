import SwiftUI
import Charts
import HomePortKit

/// One metrics feed per machine, owned by the window's root view for the same reason
/// `EventFeedStore` is: `MachineDetailView` carries `.id(machine.name)` and is recreated on
/// every machine switch, and the tab view itself is recreated on every tab switch. The range
/// a user picked, and the curves already read, must survive both.
@MainActor
final class MetricsStore: ObservableObject {
    private var feeds: [String: MetricsFeed] = [:]
    /// One client for the whole app: it owns a `URLSession`, and a per-view one would open a
    /// fresh connection pool on every tab switch.
    private let api = HomeportAPIClient()

    func entry(for name: String) -> MetricsFeed {
        if let existing = feeds[name] { return existing }
        let feed = MetricsFeed()
        feeds[name] = feed
        return feed
    }

    /// The reader both surfaces share (AD-13). It takes no store: AD-6 leaves hpm.db to the
    /// events cursor and the notification marker, and metrics have neither.
    func reader() -> HomeportMetricsReader {
        HomeportMetricsReader(api: api)
    }

    /// A machine removed from fleet.yaml must not keep a feed behind the scenes.
    func prune(keeping names: [String]) {
        feeds = feeds.filter { names.contains($0.key) }
    }
}

/// What one machine's Metrics tab shows, kept out of the view so it survives it.
@MainActor
final class MetricsFeed: ObservableObject {
    /// The window last read, whatever range it was read for. Kept through an outage so the
    /// curves stay on screen under the "unreachable" banner (UX-DR5).
    @Published private(set) var window: MetricsWindow?
    /// The range the user picked. Owned by the feed rather than the view: a tab switch
    /// recreates the view, and coming back to a machine on 30 d must not silently reset it
    /// to 24 h.
    @Published var range = HomeportMetricsReader.defaultRange
    /// Non-nil when this machine's Homeport does not serve the surface — the state that
    /// points at Updates. Mutually exclusive with `unreachable` by construction.
    @Published private(set) var unavailable: APIUnavailableReason?
    /// Non-nil when the machine did not answer. The curves already read stay on screen.
    @Published private(set) var unreachable: String?
    /// When this feed last got an answer — its own reading, deliberately kept apart from
    /// `FleetModel.lastSeenAt`, which is the ssh poll's.
    @Published private(set) var lastReachedAt: Date?
    /// A read is in flight and there is nothing on screen for it yet.
    @Published private(set) var loading = false
    /// The served epoch changed since the last successful read of this machine (§5/§7): the
    /// curves that were showing belong to a history that no longer exists. Shown as a note,
    /// never as an error.
    @Published private(set) var historyRestarted = false

    /// The epoch of the last successful read, **in memory only**. AD-6 reserves hpm.db for
    /// the events cursor and the notification marker; a generation change inside one session
    /// is all that is needed to keep two unrelated histories from being drawn as one, and
    /// that needs no durable state.
    private var epoch: String?

    /// Counts read *attempts*, not the machine and range they were started for. Last writer
    /// wins: only the most recent attempt may publish.
    ///
    /// A key of `(machine, range)` would not do, and neither would `EventFeed`'s
    /// `isFetching` bool. `retry()` spawns an unstructured `Task` that `.task(id:)` never
    /// cancels — and Retry is only ever offered on an unreachable machine, so it runs for
    /// the full timeout. Two attempts carrying the same key can therefore overlap, and the
    /// first to land would clear the guard out from under the second, publishing its own
    /// stale window and then discarding the fresh one. A per-attempt token cannot be
    /// mistaken for another attempt.
    private var generation = 0

    func read(machine: Machine, range: MetricsRange, through reader: HomeportMetricsReader) async {
        generation &+= 1
        let token = generation
        loading = window == nil || window?.range != range

        let outcome = await reader.read(machine, range: range)

        // A newer attempt superseded this one while it was in flight: its answer describes
        // a window the user has already left, and applying it would relabel the curves.
        // The newer attempt owns `loading` too, so this one must not touch it either.
        guard token == generation else { return }
        loading = false
        // A cancelled read (the tab went away mid-fetch) is not an answer from the machine:
        // nothing else published here may change because of it.
        if case .cancelled = outcome { return }
        apply(outcome)
    }

    private func apply(_ outcome: MetricsOutcome) {
        switch outcome {
        case .cancelled:
            return
        case .unavailable(let reason):
            // Not a failure, and not a machine with no measurements: this Homeport has no
            // metric history to show at all, so keeping stale curves would be a lie.
            unavailable = reason
            unreachable = nil
            historyRestarted = false
            window = nil
            epoch = nil
        case .unreachable(let detail):
            // UX-DR5: the last known curves stay, with the hour they were last read. The
            // "not available" verdict is dropped — it was an observation, and the fresher
            // one is that the machine is not answering.
            unreachable = detail
            unavailable = nil
            // The generation note belongs to a read that happened; an outage must not leave
            // it standing over data it no longer describes.
            historyRestarted = false
        case .window(let served):
            unavailable = nil
            unreachable = nil
            lastReachedAt = Date()
            // §5: an epoch compared by equality and nothing else. A change is a normal event
            // in a machine's life — the curves are replaced, and the note says why.
            historyRestarted = served.startsANewGeneration(after: epoch)
            epoch = served.epoch
            window = served
        }
    }
}

/// One metric card of the Metrics tab: the `metric-card` component of DESIGN.md — hairline
/// card, eyebrow title, current value in `sectionTitle`, ink curve on a `hairlineSoft` grid.
///
/// It renders what the kit computed and decides nothing: the runs it loops over are
/// `MetricSeries.segments`, and every instant comes from `MetricsWindow.timestamp(at:)`.
struct MetricCard: View {
    let title: LocalizedStringKey
    let series: MetricSeries
    let window: MetricsWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title)
                .styled(Theme.eyebrow)
                .foregroundStyle(Theme.ink)
                .textCase(.uppercase)
            // Machine content: a served number and its served unit, never translated.
            Text(verbatim: "\(MetricValue.text(series.current)) \(series.kind.unit)")
                .styled(Theme.sectionTitle)
                .foregroundStyle(Theme.ink)
            chart
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: Theme.Rounded.md))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Rounded.md)
                .stroke(Theme.hairline, lineWidth: Theme.Spacing.hair))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(verbatim: announcement))
    }

    /// A chart has no intrinsic height, and this card lives inside the sheet's `ScrollView`
    /// where an unconstrained one collapses to nothing. The height is a `Theme` token like
    /// every other fixed size in the app.
    private var chart: some View {
        Chart {
            // One `series:` value per contiguous run: Swift Charts joins two consecutive
            // `LineMark`s whatever was omitted between them, and §7 forbids a curve
            // crossing a hole. The runs themselves are the kit's, not this view's.
            ForEach(Array(series.segments.enumerated()), id: \.offset) { run in
                ForEach(run.element) { point in
                    AreaMark(x: .value("Time", window.timestamp(at: point.index)),
                             y: .value("Value", point.value),
                             series: .value("Run", "area-\(run.offset)"))
                        .foregroundStyle(Theme.ink.opacity(0.08))
                    LineMark(x: .value("Time", window.timestamp(at: point.index)),
                             y: .value("Value", point.value),
                             series: .value("Run", "line-\(run.offset)"))
                        .foregroundStyle(Theme.ink)
                }
            }
        }
        .chartXAxis {
            // Count and format both come from the kit: the automatic style writes a date at
            // full length, and four of those overlap on the plot a card gets at the
            // window's 900 pt minimum.
            AxisMarks(values: .automatic(desiredCount: MetricsRange.axisMarkCount)) {
                AxisGridLine().foregroundStyle(Theme.hairlineSoft)
                AxisValueLabel(format: window.range.axisDateFormat)
            }
        }
        .chartYAxis {
            // Nothing to scale means nothing to label: a series with no measurement at all
            // draws no vertical axis rather than an invented one.
            if scale != nil {
                AxisMarks {
                    AxisGridLine().foregroundStyle(Theme.hairlineSoft)
                    AxisValueLabel()
                }
            }
        }
        .chartYScale(domain: scale ?? 0...1)
        // The whole window, always: the axis must not shrink to the measured part of a
        // series that only covers its last hour.
        .chartXScale(domain: window.from...window.to)
        .frame(height: Theme.Metrics.metricChartHeight)
    }

    /// What the curve is drawn against: the scale §7 fixes when it fixes one, otherwise the
    /// extremes actually measured — widened by a unit when they coincide, since a
    /// zero-width domain collapses the axis. Nil when the series holds no measurement at
    /// all: there is no honest scale to claim for an empty card.
    private var scale: ClosedRange<Double>? {
        if let fixed = series.kind.scale { return fixed }
        guard let low = series.minimum, let high = series.maximum else { return nil }
        return low < high ? low...high : (low - 1)...(high + 1)
    }

    /// Current, then the extremes of the window: the two values a screen reader cannot get
    /// from the curve itself.
    private var announcement: String {
        let unit = series.kind.unit
        return "\(MetricValue.text(series.current)) \(unit), "
            + "min \(MetricValue.text(series.minimum)) \(unit), "
            + "max \(MetricValue.text(series.maximum)) \(unit)"
    }
}

/// The Metrics tab: a range picker, and the four series of the contract as four cards —
/// always four, even when a machine measures none of them (§7).
struct MetricsTabView: View {
    @ObservedObject var feed: MetricsFeed
    let store: MetricsStore
    let machine: Machine
    /// How the "not available" state hands the user over to Updates (UX-DR5). A closure
    /// rather than the tab enum: this view is mounted on its own by the render probe, and
    /// nothing it names may drag the rest of the app in.
    let goToUpdates: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            rangeBar
            content
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // Reads while the tab is visible and not otherwise: the metrics history lives on the
        // Pi, so there is nothing to miss by not polling — unlike the event feed, whose
        // cursor has to keep moving. Changing the range re-fires this and re-reads the same
        // machine on the new grid, without resampling anything locally.
        .task(id: "\(machine.name)|\(feed.range.rawValue)") {
            await feed.read(machine: machine, range: feed.range, through: store.reader())
        }
    }

    // MARK: Range

    private var rangeBar: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Picker(selection: $feed.range) {
                ForEach(MetricsRange.allCases, id: \.self) { option in
                    Text(Self.title(of: option)).tag(option)
                }
            } label: {
                Text("metrics.range.label")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // No fixed width: the four labels are translated, and a segmented picker sizes
            // to its content.
            .fixedSize()
            .accessibilityLabel(Text("metrics.range.label"))
            if feed.loading {
                ProgressView().controlSize(.small)
            }
            Spacer(minLength: 0)
        }
    }

    /// The catalog key of a range. The kit carries the wire value and a plain-string label
    /// for the CLI; a `LocalizedStringKey` cannot live there, so the mapping is here — the
    /// same split `EventSeverityFilter.title` already makes.
    static func title(of range: MetricsRange) -> LocalizedStringKey {
        switch range {
        case .h24: return "metrics.range.24h"
        case .d7: return "metrics.range.7d"
        case .d30: return "metrics.range.30d"
        case .y1: return "metrics.range.1y"
        }
    }

    /// The catalog key of a series, likewise.
    static func title(of kind: MetricKind) -> LocalizedStringKey {
        switch kind {
        case .cpu: return "metrics.series.cpu"
        case .memory: return "metrics.series.memory"
        case .disk: return "metrics.series.disk"
        case .temperature: return "metrics.series.temperature"
        }
    }

    // MARK: The three states of the contract

    @ViewBuilder
    private var content: some View {
        // A first read in flight with nothing on screen: never let an empty state claim a
        // machine records nothing before the read that would confirm it has returned.
        if feed.loading, feed.window == nil {
            loadingState
        } else if let reason = feed.unavailable {
            unavailableState(reason)
        } else if feed.unreachable != nil, feed.window == nil {
            EmptyStateView(
                title: "Unreachable",
                message: "\(machine.name) is unreachable. Check Tailscale or retry.",
                detail: feed.unreachable,
                actionTitle: "Retry", action: retry)
        } else if let window = feed.window {
            cards(window)
        } else {
            EmptyStateView(
                title: "No metrics yet",
                message: "This machine has not recorded any metrics yet. They appear here as its Homeport samples them.")
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

    /// UX-DR5's "does not know how to yet" state: warm, explanatory, pointing at the one
    /// thing that fixes it. Never a red pill, never the word error.
    private func unavailableState(_ reason: APIUnavailableReason) -> some View {
        EmptyStateView(
            title: "Metrics not available",
            message: "This version of Homeport does not serve metrics yet.",
            detail: detail(for: reason),
            actionTitle: "Go to Updates", action: goToUpdates)
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

    // MARK: The cards

    private func cards(_ window: MetricsWindow) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if feed.unreachable != nil {
                unreachableNotice
            }
            if feed.historyRestarted {
                Text("The metric history of this machine started a new generation — the curves shown are the new one.")
                    .styled(Theme.body)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Two columns at the nominal width, one at the window's 900pt minimum: a card
            // narrower than this draws a curve nothing can be read off.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.Metrics.metricCardMinWidth),
                                         spacing: Theme.Spacing.md)],
                      spacing: Theme.Spacing.md) {
                // Always the four, in the contract's order — a series a machine cannot
                // produce is an empty card, never a missing one (§7).
                ForEach(window.series, id: \.kind) { series in
                    MetricCard(title: Self.title(of: series.kind), series: series, window: window)
                }
            }
        }
    }

    /// UX-DR5 again: unreachable keeps the curves and says when they were last read, rather
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

    private func retry() {
        Task {
            await feed.read(machine: machine, range: feed.range, through: store.reader())
        }
    }
}
