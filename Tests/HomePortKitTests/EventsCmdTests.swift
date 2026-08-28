import XCTest
import HomePortKit
@testable import hpm

/// `hpm events` (`Sources/hpm/Commands.swift`) sits in the executable target, but it makes
/// its own decisions — validating `--severity` and `--limit`, and shaping the printed table
/// — and AD-13 requires those decisions to never drift from the Events tab's. These tests
/// cover the pure pieces directly, without a fleet.yaml or a network call.
final class EventsCmdTests: XCTestCase {

    // MARK: --severity

    func testAKnownSeverityParses() throws {
        XCTAssertEqual(try EventsCmd.parseSeverityOption("info"), .info)
        XCTAssertEqual(try EventsCmd.parseSeverityOption("WARNING"), .warning,
                       "case-insensitive, like a value typed on a command line")
        XCTAssertEqual(try EventsCmd.parseSeverityOption("critical"), .critical)
    }

    func testAnAbsentSeverityIsNilNotAnError() throws {
        XCTAssertNil(try EventsCmd.parseSeverityOption(nil))
    }

    /// A typo on the command line, not an unknown value served by a machine: it must be
    /// refused, not silently folded the way an unrecognised server-side severity is.
    func testAnUnknownSeverityOptionThrowsRatherThanFoldingToWarning() {
        XCTAssertThrowsError(try EventsCmd.parseSeverityOption("fatal")) { error in
            guard let hpm = error as? HPMError else {
                return XCTFail("expected HPMError, got \(error)")
            }
            XCTAssertTrue(hpm.message.contains("info"))
            XCTAssertTrue(hpm.message.contains("warning"))
            XCTAssertTrue(hpm.message.contains("critical"))
        }
    }

    func testAnEmptySeverityOptionThrows() {
        XCTAssertThrowsError(try EventsCmd.parseSeverityOption(""))
    }

    // MARK: --limit

    func testAnAbsentLimitDefaultsToTheReaderDefault() throws {
        XCTAssertEqual(try EventsCmd.validateLimitOption(nil), HomeportEventsReader.defaultLimit)
    }

    func testALimitInsideTheContractCeilingIsAccepted() throws {
        XCTAssertEqual(try EventsCmd.validateLimitOption(1), 1)
        XCTAssertEqual(try EventsCmd.validateLimitOption(1000), 1000)
        XCTAssertEqual(try EventsCmd.validateLimitOption(200), 200)
    }

    func testALimitBelowOneIsRejected() {
        XCTAssertThrowsError(try EventsCmd.validateLimitOption(0))
        XCTAssertThrowsError(try EventsCmd.validateLimitOption(-5))
    }

    func testALimitAboveTheContractCeilingIsRejected() {
        XCTAssertThrowsError(try EventsCmd.validateLimitOption(1001)) { error in
            guard let hpm = error as? HPMError else {
                return XCTFail("expected HPMError, got \(error)")
            }
            XCTAssertTrue(hpm.message.contains("1000"), "names the contract's own ceiling")
        }
    }

    // MARK: The printed table's shape (AD-13: the same format the tab implies)

    private func event(_ id: Int64, _ severity: EventSeverity, kind: String = "service.up",
                       subject: String = "homeassistant", detail: String? = nil) -> HomeportEvent {
        HomeportEvent(id: id, timestamp: Date(timeIntervalSince1970: TimeInterval(id)),
                      kind: kind, severity: severity, subject: subject, detail: detail)
    }

    func testTheTableHasTheDocumentedHeader() {
        let rows = EventsCmd.rows(for: [event(1, .info)])
        XCTAssertEqual(rows.first, ["ID", "DATE", "SEVERITY", "KIND", "SUBJECT", "DETAIL"])
    }

    /// Newest first — `hpm tasks`'s own convention, and the tab's (reversed at the point
    /// of display in both places for the same reason).
    func testTheTableListsNewestFirst() {
        let events = [event(1, .info), event(2, .warning), event(3, .critical)]
        let rows = EventsCmd.rows(for: events)
        XCTAssertEqual(rows.dropFirst().map { $0[0] }, ["3", "2", "1"])
    }

    func testAMissingDetailRendersAsADash() {
        let rows = EventsCmd.rows(for: [event(1, .info, detail: nil)])
        XCTAssertEqual(rows[1][5], "-")
    }

    func testAPresentDetailIsCarriedThroughVerbatim() {
        let rows = EventsCmd.rows(for: [event(1, .warning, detail: "71 °C")])
        XCTAssertEqual(rows[1][5], "71 °C")
    }

    /// The format both surfaces owe AD-13: severity as the contract's own raw word, kind
    /// and subject carried through untouched — never re-derived per call site.
    func testEachRowCarriesTheContractsOwnFields() {
        let rows = EventsCmd.rows(for: [event(42, .critical, kind: "service.down", subject: "homeassistant")])
        let row = rows[1]
        XCTAssertEqual(row[0], "42")
        XCTAssertEqual(row[2], "critical")
        XCTAssertEqual(row[3], "service.down")
        XCTAssertEqual(row[4], "homeassistant")
    }

    /// The severity filter itself is `HomePortKit`'s (`filtered(severity:)`, already
    /// covered in `ManagerEventsTests`); this only checks that filtering ahead of
    /// `rows(for:)` produces exactly the filtered table AD-13 requires.
    func testAFilteredSetProducesOnlyMatchingRows() {
        let events = [event(1, .info), event(2, .warning), event(3, .critical)]
        let rows = EventsCmd.rows(for: events.filtered(severity: .warning))
        XCTAssertEqual(rows.count, 2, "header plus exactly the one matching event")
        XCTAssertEqual(rows[1][2], "warning")
    }
}
