import Foundation

/// Reading a machine's historised metrics: the handshake, the `features` guard, and the
/// window that comes out of it. One reader serves both the Metrics tab and `hpm metrics`
/// (AD-13), so the two can never show different curves.
///
/// Everything decidable about a window — the grid, the segmentation of the holes, the
/// current/min/max of a series — lives in `HomeportAPIClient`'s value types, where
/// `swift test` exercises it. What is left here is the one order of operations §4 fixes:
/// `capabilities` first, `metrics` only if `features` says so.
///
/// **No store, on purpose.** AD-6 keeps `hpm.db` for the events cursor and the notification
/// marker; metrics have neither. There is nothing to persist between two reads, so this
/// reader takes no store — copying `HomeportEventsReader`'s `cursors` plumbing by symmetry
/// would be a false parallel.
public struct HomeportMetricsReader: Sendable {
    /// The range a caller gets when it does not name one — the contract's own default (§7).
    public static let defaultRange = MetricsRange.h24

    private let api: HomeportMetricsReading

    public init(api: HomeportMetricsReading) {
        self.api = api
    }

    /// Reads one window of a machine's metrics.
    ///
    /// Returns the same three states as the events reader, for the same reason: §8 makes
    /// none of them an error, so the interface renders one switch and catches nothing.
    public func read(_ machine: Machine,
                     range: MetricsRange = HomeportMetricsReader.defaultRange) async -> MetricsOutcome {
        switch await api.capabilities(of: machine) {
        case .unreachable(let detail):
            return .unreachable(detail)
        case .unavailable(let reason):
            return .unavailable(reason)
        case .cancelled:
            return .cancelled
        case .available(let capabilities):
            // §4: `features` is the source of truth, and a client does not probe an
            // endpoint to discover whether it exists. An instance that serves events and
            // not metrics is "not available" on this tab only.
            guard capabilities.serves(HomeportAPIClient.metricsFeature) else {
                return .unavailable(.surfaceNotServed(HomeportAPIClient.metricsFeature))
            }
            return await api.metrics(of: machine, range: range)
        }
    }
}

// MARK: - Generation change

extension MetricsWindow {
    /// Whether this window belongs to a different generation of the history than the last
    /// one read (§5, §7).
    ///
    /// The epoch is opaque: compared by equality and nothing else. A change means the curves
    /// that were on screen do not join onto these — they are replaced, and the note says why.
    /// A *first* read has nothing to differ from and never raises it: an interface that
    /// announced a new generation the first time it ever looked would be announcing the
    /// machine's own history to itself.
    ///
    /// Decidable, so it lives here rather than in a view: `App/Sources` is compiled by the
    /// verify gate and covered by no unit test.
    public func startsANewGeneration(after previous: String?) -> Bool {
        guard let previous else { return false }
        return previous != epoch
    }
}
