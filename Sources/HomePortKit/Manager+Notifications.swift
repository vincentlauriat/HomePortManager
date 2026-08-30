import Foundation

/// Deciding whether a background poll's critical events should notify, and whether a
/// machine's Homeport events policy is available enough to carry that decision at all
/// (story 2.2b). Both are pure — no network, no database — so `swift test` exercises the
/// exact decision `FleetModel`'s background poll (App/Sources, outside the SwiftPM graph —
/// DW-21) applies every 45 s.

/// The Mac-side marker of the newest event id already notified for a machine, plus the
/// epoch that id belongs to. Mirrors `EventCursor` (`Manager+Events.swift`) in shape, for
/// the same reason: a second, independent position in the same history, read and advanced
/// on its own — never merged with the read cursor `event_cursors` owns (AD-6).
public struct NotifiedMarker: Equatable, Sendable {
    public let epoch: String
    public let notifiedUpTo: Int64

    public init(epoch: String, notifiedUpTo: Int64) {
        self.epoch = epoch
        self.notifiedUpTo = notifiedUpTo
    }
}

/// Where the notification marker lives. `HistoryStore` is the production one — same
/// doctrine as `EventCursorStore`.
public protocol NotifiedMarkerStore: AnyObject, Sendable {
    func notifiedMarker(machine: String) throws -> NotifiedMarker?
    func setNotifiedMarker(_ marker: NotifiedMarker, machine: String, now: Date) throws
}

extension HistoryStore: NotifiedMarkerStore {}

/// Which events in a freshly read window should notify, and where the marker moves to.
///
/// `notifiedMarker == nil` and `notifiedMarker.epoch != window.epoch` are treated
/// *exactly* the same way: both mean "this marker says nothing about the current epoch" —
/// a first pull for this machine and a reset/restore on the Pi that started a new
/// generation are the same situation from the marker's point of view, so both
/// re-initialize silently at the window's `latestID` with nothing to notify. This is the
/// same "no retroactive notification on an already-populated history" doctrine that
/// governs a machine's very first pull, applied again: a reset produces, from this
/// marker's perspective, a history exactly as new. Comparing against `window.latestID`
/// (never against the greatest `id` inside `window.events`, which a trim to `limit` could
/// leave short of the epoch's real newest id) is what makes the marker correct even when
/// the window was clipped.
///
/// When the marker does belong to `window.epoch`, only `.critical` events with
/// `id > notifiedMarker.notifiedUpTo` notify; the returned marker always advances to (at
/// least) `window.latestID`, whatever severity was actually seen — a `warning`/`info`
/// beyond the old marker must not be re-examined on the next poll just because nothing
/// notified for it.
public func notifiableCriticalEvents(
    in window: EventWindow, notifiedMarker: NotifiedMarker?
) -> (toNotify: [HomeportEvent], newMarker: NotifiedMarker) {
    guard let notifiedMarker, notifiedMarker.epoch == window.epoch else {
        return (toNotify: [], newMarker: NotifiedMarker(epoch: window.epoch, notifiedUpTo: window.latestID))
    }
    let toNotify = window.events.filter { $0.id > notifiedMarker.notifiedUpTo && $0.severity == .critical }
    let advanced = max(notifiedMarker.notifiedUpTo, window.latestID)
    return (toNotify: toNotify, newMarker: NotifiedMarker(epoch: window.epoch, notifiedUpTo: advanced))
}

/// The sticky decision of whether a machine's events policy is available, from one
/// background poll's read. `.window` turns it on; only an explicit `.unavailable` (an
/// incompatible or absent version — a configuration fact, never a network blip) turns it
/// back off. `.unreachable` and `.cancelled` are transient — a poll that failed to answer
/// says nothing about the policy, so the caller must keep whatever it already believed
/// (`nil` here means "no change"), never flap between the events and SSH-transitions
/// policies on a single missed poll.
public func eventsPolicyAvailability(for read: EventsRead) -> Bool? {
    switch read {
    case .window: return true
    case .unavailable: return false
    case .unreachable, .cancelled: return nil
    }
}
