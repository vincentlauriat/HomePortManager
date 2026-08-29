import XCTest
import SQLite3
@testable import HomePortKit

/// The pure decision behind story 2.2b's notification policy: which critical events in a
/// freshly read window should notify, and how the events-availability sticky flag reads a
/// poll's outcome. Both are exercised here without a network or a database — same doctrine
/// as `ManagerEventsTests`. The `HistoryStore` side of the marker (read/write/clear,
/// corruption guard, migration) is covered at the bottom.
final class ManagerNotificationsTests: XCTestCase {
    private func event(_ id: Int64, _ severity: EventSeverity, kind: String = "service.up",
                       subject: String = "homeassistant") -> HomeportEvent {
        HomeportEvent(id: id, timestamp: Date(timeIntervalSince1970: TimeInterval(id)),
                      kind: kind, severity: severity, subject: subject, detail: nil)
    }

    private func window(epoch: String = "epoch-1", latestID: Int64, events: [HomeportEvent],
                        cursorWasReset: Bool = false, isFullWindow: Bool = true) -> EventWindow {
        EventWindow(epoch: epoch, latestID: latestID, events: events,
                   cursorWasReset: cursorWasReset, isFullWindow: isFullWindow)
    }

    // MARK: The three ACs

    /// Given a critical event beyond the marker, when the window is decided, then it
    /// notifies and the marker advances to the window's `latestID`.
    func testACriticalEventBeyondTheMarkerNotifiesAndAdvancesTheMarker() {
        let events = [event(9, .info), event(10, .critical)]
        let marker = NotifiedMarker(epoch: "epoch-1", notifiedUpTo: 9)
        let decision = notifiableCriticalEvents(in: window(latestID: 10, events: events),
                                                notifiedMarker: marker)
        XCTAssertEqual(decision.toNotify.map(\.id), [10])
        XCTAssertEqual(decision.newMarker, NotifiedMarker(epoch: "epoch-1", notifiedUpTo: 10))
    }

    /// A first pull for a machine that never had a marker — even with `critical` already on
    /// the first page — initializes silently: nothing retroactive notifies.
    func testAFirstPullWithNoStoredMarkerInitializesSilentlyEvenWithCriticalAlreadyPresent() {
        let events = [event(1, .critical), event(2, .warning)]
        let decision = notifiableCriticalEvents(in: window(latestID: 2, events: events),
                                                notifiedMarker: nil)
        XCTAssertTrue(decision.toNotify.isEmpty)
        XCTAssertEqual(decision.newMarker, NotifiedMarker(epoch: "epoch-1", notifiedUpTo: 2))
    }

    /// A non-critical event beyond the marker advances the marker without notifying.
    func testANonCriticalEventBeyondTheMarkerAdvancesWithoutNotifying() {
        let events = [event(11, .warning), event(12, .info)]
        let marker = NotifiedMarker(epoch: "epoch-1", notifiedUpTo: 10)
        let decision = notifiableCriticalEvents(in: window(latestID: 12, events: events),
                                                notifiedMarker: marker)
        XCTAssertTrue(decision.toNotify.isEmpty)
        XCTAssertEqual(decision.newMarker, NotifiedMarker(epoch: "epoch-1", notifiedUpTo: 12))
    }

    // MARK: Epoch reset — the regression the two review passes of this story closed

    /// `notifiedMarker.epoch != window.epoch` is treated exactly like an absent marker:
    /// silent re-initialization, nothing retroactive.
    func testAMarkerFromADifferentEpochIsTreatedAsAbsent() {
        let events = [event(1, .critical)]
        let marker = NotifiedMarker(epoch: "epoch-old", notifiedUpTo: 500)
        let decision = notifiableCriticalEvents(in: window(epoch: "epoch-new", latestID: 1, events: events),
                                                notifiedMarker: marker)
        XCTAssertTrue(decision.toNotify.isEmpty)
        XCTAssertEqual(decision.newMarker, NotifiedMarker(epoch: "epoch-new", notifiedUpTo: 1))
    }

    /// The exact regression of the 2ᵉ passe de revue: a machine whose Events tab has
    /// *never* been opened has no `event_cursors` row, ever — `cursorWasReset` would stay
    /// `false` forever for it, and a reset detection built on that would miss the reset
    /// entirely. The epoch carried on the marker itself has no such dependency: two
    /// consecutive polls where the epoch changes between them must still be caught, purely
    /// from the stored `NotifiedMarker`, with no `event_cursors` row involved at any point
    /// in this test.
    func testAnEpochChangeBetweenTwoPollsIsCaughtWithNoEventCursorsRowEverExisting() {
        // First poll: no marker yet (as if the tab had never been opened) — silent init.
        let firstEvents = [event(1, .info), event(2, .critical)]
        let firstDecision = notifiableCriticalEvents(
            in: window(epoch: "epoch-1", latestID: 2, events: firstEvents), notifiedMarker: nil)
        XCTAssertTrue(firstDecision.toNotify.isEmpty, "first pull is always silent")
        XCTAssertEqual(firstDecision.newMarker, NotifiedMarker(epoch: "epoch-1", notifiedUpTo: 2))

        // A restore/reflash on the Pi between the two polls: new epoch, ids restart at 1,
        // with a critical event right away. Without the epoch riding on the marker itself,
        // this would compare id 1 against notifiedUpTo 2 from the old generation and drop
        // it silently — exactly the bad_spec finding of the 2ᵉ passe.
        let secondEvents = [event(1, .critical)]
        let secondDecision = notifiableCriticalEvents(
            in: window(epoch: "epoch-2", latestID: 1, events: secondEvents),
            notifiedMarker: firstDecision.newMarker)
        XCTAssertTrue(secondDecision.toNotify.isEmpty,
                      "a reset behaves like a first pull: silent, never retroactive")
        XCTAssertEqual(secondDecision.newMarker, NotifiedMarker(epoch: "epoch-2", notifiedUpTo: 1))

        // But the *next* critical event of the new generation must notify normally — the
        // marker is not stuck silent forever, only re-initialized once per reset.
        let thirdEvents = [event(1, .critical), event(2, .critical)]
        let thirdDecision = notifiableCriticalEvents(
            in: window(epoch: "epoch-2", latestID: 2, events: thirdEvents),
            notifiedMarker: secondDecision.newMarker)
        XCTAssertEqual(thirdDecision.toNotify.map(\.id), [2])
    }

    // MARK: eventsPolicyAvailability — the 4 cases

    func testWindowMakesThePolicyAvailable() {
        XCTAssertEqual(eventsPolicyAvailability(for: .window(window(latestID: 0, events: []))), true)
    }

    func testUnavailableTurnsThePolicyOff() {
        XCTAssertEqual(eventsPolicyAvailability(for: .unavailable(.notServed)), false)
    }

    func testUnreachableIsNoChange() {
        XCTAssertNil(eventsPolicyAvailability(for: .unreachable("HTTP 500")),
                     "a transient failure must never flap the sticky policy")
    }

    func testCancelledIsNoChange() {
        XCTAssertNil(eventsPolicyAvailability(for: .cancelled))
    }

    // MARK: HistoryStore.notifiedMarker / setNotifiedMarker / clearNotifiedUpTo

    func testNotifiedMarkerRoundTripsReadsWritesClearsAndGuardsCorruption() throws {
        let root = NSTemporaryDirectory() + "hpm-notifications-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let path = root + "/state/hpm/hpm.db"

        let store = try HistoryStore(path: path)
        XCTAssertNil(try store.notifiedMarker(machine: "raspcorse"), "never notified yet is nil")

        try store.setNotifiedMarker(NotifiedMarker(epoch: "epoch-1", notifiedUpTo: 42), machine: "raspcorse")
        XCTAssertEqual(try store.notifiedMarker(machine: "raspcorse"),
                       NotifiedMarker(epoch: "epoch-1", notifiedUpTo: 42))

        // A reset replaces the row outright, mirroring `setEventCursor`.
        try store.setNotifiedMarker(NotifiedMarker(epoch: "epoch-2", notifiedUpTo: 3), machine: "raspcorse")
        XCTAssertEqual(try store.notifiedMarker(machine: "raspcorse"),
                       NotifiedMarker(epoch: "epoch-2", notifiedUpTo: 3))
        XCTAssertNil(try store.notifiedMarker(machine: "raspyellow"), "markers are per machine")

        try store.clearNotifiedUpTo(machine: "raspcorse")
        XCTAssertNil(try store.notifiedMarker(machine: "raspcorse"))
        XCTAssertNoThrow(try store.clearNotifiedUpTo(machine: "raspcorse"), "clearing twice is idempotent")

        // Corruption (a negative id nothing here ever writes) surfaces as an error, not as
        // "never notified" — same doctrine as `eventCursor`.
        try store.setNotifiedMarker(NotifiedMarker(epoch: "epoch-1", notifiedUpTo: 7), machine: "raspcorse")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        XCTAssertEqual(sqlite3_exec(db, "UPDATE notified_markers SET notified_up_to = -1 WHERE machine = 'raspcorse';",
                                    nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try store.notifiedMarker(machine: "raspcorse"))
    }

    /// The v2 base of story 2.2a (events cursor only) receives `notified_markers` on
    /// migration to v4, and the events cursor it already held survives untouched.
    func testAV2DatabaseIsMigratedToV4WithoutLosingTheEventCursor() throws {
        let root = NSTemporaryDirectory() + "hpm-notifications-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let path = root + "/state/hpm/hpm.db"

        // A genuine v2 base, written without the code under test.
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        let schema = """
        CREATE TABLE tasks (
            id INTEGER PRIMARY KEY AUTOINCREMENT, started_at TEXT NOT NULL, finished_at TEXT,
            machine TEXT NOT NULL, action TEXT NOT NULL, status TEXT NOT NULL,
            output TEXT NOT NULL DEFAULT ''
        );
        CREATE TABLE locks (
            machine TEXT PRIMARY KEY, pid INTEGER NOT NULL, acquired_at TEXT NOT NULL, task_id INTEGER
        );
        CREATE TABLE event_cursors (
            machine TEXT PRIMARY KEY, epoch TEXT NOT NULL, last_id INTEGER NOT NULL, updated_at TEXT NOT NULL
        );
        INSERT INTO event_cursors (machine, epoch, last_id, updated_at)
        VALUES ('raspcorse', 'epoch-1', 42, '2026-08-24T10:00:00Z');
        PRAGMA user_version = 2;
        """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
        sqlite3_close_v2(db)

        let store = try HistoryStore(path: path)
        XCTAssertEqual(try store.eventCursor(machine: "raspcorse"), EventCursor(epoch: "epoch-1", id: 42),
                       "the v2 events cursor survives the migration to v4 untouched")
        XCTAssertNil(try store.notifiedMarker(machine: "raspcorse"), "the new table starts empty")
        try store.setNotifiedMarker(NotifiedMarker(epoch: "epoch-1", notifiedUpTo: 42), machine: "raspcorse")
        XCTAssertEqual(try store.notifiedMarker(machine: "raspcorse"),
                       NotifiedMarker(epoch: "epoch-1", notifiedUpTo: 42))
    }
}
