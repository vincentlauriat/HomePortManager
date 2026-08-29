import XCTest
import HomePortKit
@testable import hpm

/// `hpm machine remove`'s marker cleanup (`MachineCmd.Remove.clearMarkers`), pulled out of
/// `run()` for the same reason `EventsCmd`'s pure pieces are: it can be exercised against a
/// throwaway `HistoryStore` without touching the real `~/.local/state/hpm/hpm.db` `run()`
/// hard-codes. Until this story this path — clearing both the events cursor and the
/// notification marker on removal — had no test at any level.
final class MachineCmdRemoveTests: XCTestCase {
    func testClearMarkersRemovesBothTheEventCursorAndTheNotifiedMarker() throws {
        let root = NSTemporaryDirectory() + "hpm-remove-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = try HistoryStore(path: root + "/state/hpm/hpm.db")

        try store.setEventCursor(EventCursor(epoch: "epoch-1", id: 10), machine: "raspcorse")
        try store.setNotifiedMarker(NotifiedMarker(epoch: "epoch-1", notifiedUpTo: 10), machine: "raspcorse")

        var warnings: [String] = []
        MachineCmd.Remove.clearMarkers(for: "raspcorse", in: store) { warnings.append($0) }

        XCTAssertNil(try store.eventCursor(machine: "raspcorse"))
        XCTAssertNil(try store.notifiedMarker(machine: "raspcorse"))
        XCTAssertTrue(warnings.isEmpty, "a clean clear reports nothing")
    }

    /// A machine with no markers at all (never read, never notified) clears cleanly —
    /// `clearEventCursor`/`clearNotifiedUpTo` are idempotent on an absent row.
    func testClearMarkersOnAMachineWithNoMarkersIsANoOp() throws {
        let root = NSTemporaryDirectory() + "hpm-remove-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = try HistoryStore(path: root + "/state/hpm/hpm.db")

        var warnings: [String] = []
        MachineCmd.Remove.clearMarkers(for: "ghost", in: store) { warnings.append($0) }

        XCTAssertTrue(warnings.isEmpty)
    }
}
