import Foundation

/// Reading a machine's event journal: the cursor, its invalidation, the pagination, and
/// the window that comes out of it. One reader serves both the Events tab and
/// `hpm events` (AD-13), so the two can never show different things.
///
/// Everything here is decided against `docs/api/homeport-api-v1.md` §5 and §6 and is pure
/// with respect to the network: the API is a protocol and the cursor store is a protocol,
/// so `swift test` exercises the real decision table without a socket or a database.

/// A client's position in a machine's history: the `(epoch, id)` couple of §5. The epoch is
/// opaque and compared only by equality; the id is the last event this Mac has read.
public struct EventCursor: Equatable, Sendable {
    public let epoch: String
    public let id: Int64

    public init(epoch: String, id: Int64) {
        self.epoch = epoch
        self.id = id
    }
}

/// Where the cursor lives. `HistoryStore` is the production one; AD-6 forbids any other
/// durable Mac-side state for this surface.
public protocol EventCursorStore: AnyObject, Sendable {
    func eventCursor(machine: String) throws -> EventCursor?
    func setEventCursor(_ cursor: EventCursor, machine: String, now: Date) throws
}

extension HistoryStore: EventCursorStore {}

/// What a read asks for.
public enum EventsReadMode: Equatable, Sendable {
    /// The whole current epoch, paged to `has_more == false`, trimmed to the most recent
    /// `limit`. What a freshly opened tab asks for, and what every `hpm events` asks for.
    ///
    /// Deliberately *not* gated by the stored cursor: two surfaces reading at the same
    /// instant must show the same events (AD-13), and a window that started where the
    /// cursor happened to sit would differ between them the moment either one advanced it.
    case window
    /// Only what appeared after the stored cursor — an open tab's poll tick. Falls back to
    /// a full window when the cursor turns out to be invalid (§5).
    case sinceCursor
}

/// The result of a read: the same three states as the contract's, so the interface renders
/// one switch and nothing else.
public enum EventsRead: Equatable, Sendable {
    case window(EventWindow)
    case unavailable(APIUnavailableReason)
    case unreachable(String)
    /// The read's own task was cancelled mid-fetch (e.g. a tab switch) — never a verdict
    /// about the machine. `EventFeed` must never apply this as though the machine failed
    /// to answer, and nothing here writes the cursor for it.
    case cancelled
}

/// What a successful read produced.
public struct EventWindow: Equatable, Sendable {
    public let epoch: String
    public let latestID: Int64
    /// Oldest first, as the contract serves them (§6). The display reverses; the kit does
    /// not, so the reading order stays the contract's.
    public let events: [HomeportEvent]
    /// True when the stored cursor did not belong to the served history and the read
    /// restarted from the beginning of the current epoch. §5: a normal event in a
    /// machine's life, never an error — the interface may say so, must not alarm.
    public let cursorWasReset: Bool
    /// True when this window is the whole epoch rather than an increment — what tells a
    /// caller to replace what it shows instead of appending to it.
    public let isFullWindow: Bool

    public init(epoch: String, latestID: Int64, events: [HomeportEvent],
                cursorWasReset: Bool, isFullWindow: Bool) {
        self.epoch = epoch
        self.latestID = latestID
        self.events = events
        self.cursorWasReset = cursorWasReset
        self.isFullWindow = isFullWindow
    }
}

public struct HomeportEventsReader: Sendable {
    /// The contract's own default page size (§6). Also the window size: an epoch longer
    /// than this is paged through in full and then trimmed to its most recent slice.
    public static let defaultLimit = 200

    /// A safety valve, not a policy. Forward progress is already guaranteed — ids increase
    /// strictly inside an epoch and the loop stops when a page fails to advance past the
    /// id it asked from — so this only catches a server that keeps `has_more` true
    /// forever. At the default limit it still covers 200 000 events.
    private static let maxPages = 1_000

    private let api: HomeportEventsReading
    /// nil when hpm.db could not be opened, or when the caller must not create it: the
    /// read still works, it simply detects no reset across process lifetimes.
    private let cursors: EventCursorStore?

    public init(api: HomeportEventsReading, cursors: EventCursorStore? = nil) {
        self.api = api
        self.cursors = cursors
    }

    /// Reads a machine's events.
    ///
    /// - Parameter advancingCursor: whether the stored cursor moves. The app passes true —
    ///   it is the cursor's only writer. `hpm events` passes false: a CLI listing that
    ///   consumed the cursor would blind the tab's next incremental poll, and reading a
    ///   journal is not the same act as marking it read.
    public func read(_ machine: Machine,
                     mode: EventsReadMode = .window,
                     limit: Int = HomeportEventsReader.defaultLimit,
                     advancingCursor: Bool = false,
                     now: Date = Date()) async -> EventsRead {
        let limit = min(max(limit, 1), 1000)
        let stored = try? cursors?.eventCursor(machine: machine.name)

        switch await api.capabilities(of: machine) {
        case .unreachable(let detail):
            return .unreachable(detail)
        case .unavailable(let reason):
            return .unavailable(reason)
        case .cancelled:
            return .cancelled
        case .available(let capabilities):
            // §4: `features` is the source of truth. An instance that does not serve
            // events is "not available" on this tab only — nothing else about it changes.
            guard capabilities.serves(HomeportAPIClient.eventsFeature) else {
                return .unavailable(.surfaceNotServed(HomeportAPIClient.eventsFeature))
            }
            return await pull(machine, mode: mode, limit: limit, stored: stored,
                              advancingCursor: advancingCursor, now: now)
        }
    }

    private func pull(_ machine: Machine, mode: EventsReadMode, limit: Int,
                      stored: EventCursor?, advancingCursor: Bool, now: Date) async -> EventsRead {
        var reset = false
        var isFullWindow = true
        var outcome: PagingOutcome

        switch (mode, stored) {
        case (.sinceCursor, .some(let cursor)):
            outcome = await pageThrough(machine, from: cursor.id, sinceEpoch: cursor.epoch, limit: limit)
            isFullWindow = false
        case (.sinceCursor, .none), (.window, _):
            // No cursor yet, or a full window was asked for: pull from the start of the
            // epoch. `since_epoch` is left out on purpose — there is nothing to invalidate
            // when the pull starts at zero, and sending a stale one would only make the
            // server do the reset it is already doing.
            outcome = await pageThrough(machine, from: 0, sinceEpoch: nil, limit: limit)
        }

        // §5, either condition: the epoch moved, or `latest_id` fell below the position
        // being pulled from. Both mean the same thing and have the same remedy — start
        // over at the beginning of the current epoch — and neither is an error. This also
        // covers a generation change caught *during* a pass that already started at zero:
        // what was collected belongs to a history that no longer exists, and one more pass
        // picks up the new generation now rather than leaving the tab briefly empty on a
        // machine that has a full history. Once, not in a loop: a server flipping epochs
        // faster than a pull completes has a problem no retry count fixes.
        if case .stale = outcome {
            reset = true
            isFullWindow = true
            outcome = await pageThrough(machine, from: 0, sinceEpoch: nil, limit: limit)
        }

        switch outcome {
        case .unavailable(let reason):
            return .unavailable(reason)
        case .unreachable(let detail):
            return .unreachable(detail)
        case .cancelled:
            return .cancelled
        case .stale(let epoch):
            // Twice in a row. Report the reset and let the next poll try again — the
            // window is empty for one interval, which is honest: nothing stable was read.
            if advancingCursor { store(EventCursor(epoch: epoch, id: 0), machine: machine, now: now) }
            return .window(EventWindow(epoch: epoch, latestID: 0, events: [],
                                       cursorWasReset: true, isFullWindow: true))
        case .collected(let epoch, let latestID, let events):
            // An epoch that differs from the stored one is a reset even when the pull
            // never needed to restart — a `.window` read starts at zero either way, and
            // the caller still has to know the history it was showing is gone.
            if let stored, stored.epoch != epoch { reset = true }
            // §6 serves ascending, so the *tail* is the most recent. Trimming the head is
            // what keeps a history longer than `limit` from pinning the display to its
            // oldest events — the bug this story was split out of found once already.
            let window = Array(events.suffix(limit))
            if advancingCursor {
                // The cursor follows the last event actually read. With none read it holds
                // its place inside the same epoch, and falls back to the start of a new one.
                let id = events.last?.id ?? (stored?.epoch == epoch ? (stored?.id ?? 0) : 0)
                store(EventCursor(epoch: epoch, id: id), machine: machine, now: now)
            }
            return .window(EventWindow(epoch: epoch, latestID: latestID, events: window,
                                       cursorWasReset: reset, isFullWindow: isFullWindow || reset))
        }
    }

    /// A cursor that cannot be written must not fail a read: the events are on screen
    /// either way, and hpm.db is allowed to be missing or busy. The trace goes where every
    /// other silent journal failure goes.
    private func store(_ cursor: EventCursor, machine: Machine, now: Date) {
        do {
            try cursors?.setEventCursor(cursor, machine: machine.name, now: now)
        } catch {
            FileHandle.standardError.write(
                Data("warning: could not store the events cursor of \(machine.name) — \(error)\n".utf8))
        }
    }

    private enum PagingOutcome {
        case collected(epoch: String, latestID: Int64, events: [HomeportEvent])
        /// The position this pull started from does not belong to the history being
        /// served (§5). Carries the epoch actually served.
        case stale(epoch: String)
        case unavailable(APIUnavailableReason)
        case unreachable(String)
        case cancelled
    }

    /// One ascending pass from `startID` to the end of the history, following `has_more`.
    ///
    /// The contract offers no way to ask for "the most recent events" — only this forward
    /// pull (§6). Stopping at the first page would therefore pin the display to the oldest
    /// events of any epoch longer than `limit`, silently. So the pass runs to
    /// `has_more == false` and the caller keeps the tail.
    private func pageThrough(_ machine: Machine, from startID: Int64, sinceEpoch: String?,
                             limit: Int) async -> PagingOutcome {
        var since = startID
        var collected: [HomeportEvent] = []
        var pagingEpoch: String? = nil
        var latestID: Int64 = 0

        for _ in 0..<Self.maxPages {
            switch await api.events(of: machine, sinceID: since, sinceEpoch: sinceEpoch, limit: limit) {
            case .unavailable(let reason):
                return .unavailable(reason)
            case .unreachable(let detail):
                return .unreachable(detail)
            case .cancelled:
                return .cancelled
            case .page(let page):
                // §5 condition 1, on the first page against the cursor's epoch and on
                // every later one against the epoch this pass started reading: a history
                // that changes generation mid-pagination makes what was collected
                // unrelated to what is coming.
                if let expected = pagingEpoch ?? sinceEpoch, page.epoch != expected {
                    return .stale(epoch: page.epoch)
                }
                // §5 condition 2. Only meaningful past zero: `latest_id` is 0 on an empty
                // history, and a pull from the start has nothing to be behind.
                if since > 0, page.latestID < since {
                    return .stale(epoch: page.epoch)
                }
                pagingEpoch = page.epoch
                latestID = page.latestID
                collected.append(contentsOf: page.events)
                // A `has_more` that is true with no event, or with a last id that did not
                // move past what was asked, is a server that cannot advance the pull. Stop
                // with what is in hand rather than loop on it.
                guard page.hasMore, let last = page.events.last?.id, last > since else {
                    return .collected(epoch: page.epoch, latestID: page.latestID, events: collected)
                }
                since = last
            }
        }
        return .collected(epoch: pagingEpoch ?? "", latestID: latestID, events: collected)
    }
}

// MARK: - Filtering

extension Array where Element == HomeportEvent {
    /// The one filter both surfaces apply, so `hpm events --severity` and the tab's picker
    /// can never disagree about what a severity selects (AD-13). A nil severity is "all",
    /// which is what the CLI's absent option and the picker's first segment both mean.
    public func filtered(severity: EventSeverity?) -> [HomeportEvent] {
        guard let severity else { return self }
        return filter { $0.severity == severity }
    }
}
