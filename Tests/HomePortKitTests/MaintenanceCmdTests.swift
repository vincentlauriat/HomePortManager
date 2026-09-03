import XCTest
// `ExploitAuditEntry` has no explicit `public init` (only its properties are public), so its
// memberwise initializer is internal — @testable, unlike EventsCmdTests's plain `import
// HomePortKit`, is what lets this file build one for `rows(for:)`.
@testable import HomePortKit
@testable import hpm

/// `hpm maintenance`'s own decisions in the executable target — `--limit` validation and the
/// exact shape of `history`'s printed table — mirroring `EventsCmdTests`/`MetricsCmdTests`.
/// Everything else the group does (the dry-run/execute flow, the lock, the journal) belongs
/// to `HomeportManager` and is covered by `ManagerMaintenanceTests`; `describe(_:)` itself is
/// also covered there, next to the states it renders.
final class MaintenanceCmdTests: XCTestCase {

    // MARK: history --limit

    func testAnAbsentLimitDefaultsToFifty() throws {
        XCTAssertEqual(try MaintenanceCmd.History.validateLimitOption(nil), 50)
    }

    func testALimitInsideTheContractCeilingIsAccepted() throws {
        XCTAssertEqual(try MaintenanceCmd.History.validateLimitOption(1), 1)
        XCTAssertEqual(try MaintenanceCmd.History.validateLimitOption(1000), 1000)
        XCTAssertEqual(try MaintenanceCmd.History.validateLimitOption(200), 200)
    }

    func testALimitBelowOneIsRejected() {
        XCTAssertThrowsError(try MaintenanceCmd.History.validateLimitOption(0))
        XCTAssertThrowsError(try MaintenanceCmd.History.validateLimitOption(-5))
    }

    /// §8 : pas de borne haute imposée côté serveur — le client s'en impose une pour ne
    /// jamais demander une valeur déraisonnable, comme `EventsCmd.validateLimitOption`.
    func testALimitAboveOneThousandIsRejected() {
        XCTAssertThrowsError(try MaintenanceCmd.History.validateLimitOption(1001)) { error in
            guard let hpm = error as? HPMError else {
                return XCTFail("expected HPMError, got \(error)")
            }
            XCTAssertTrue(hpm.message.contains("1000"), hpm.message)
        }
    }

    // MARK: history's table

    private func entry(_ identity: String, action: String = "apt-update", params: String = "{}",
                       dryRun: Bool, ok: Bool, message: String = "détail") -> ExploitAuditEntry {
        ExploitAuditEntry(timestamp: Date(timeIntervalSince1970: 1_756_041_600), identity: identity,
                          action: action, params: params, dryRun: dryRun, ok: ok, message: message)
    }

    func testTheTableHasTheDocumentedHeader() {
        let rows = MaintenanceCmd.History.rows(for: [entry("admin@example.com", dryRun: true, ok: true)])
        XCTAssertEqual(rows.first, ["DATE", "IDENTITY", "ACTION", "PARAMS", "DRY-RUN", "STATUS", "MESSAGE"])
    }

    /// `dryRun` et `ok` sont deux `Bool` adjacents passés au même constructeur de ligne — une
    /// inversion compile et passe sans être détectée si les quatre combinaisons ne sont pas
    /// couvertes séparément.
    func testDryRunAndOkRenderIndependentlyAcrossAllFourCombinations() {
        let rows = MaintenanceCmd.History.rows(for: [
            entry("a", dryRun: true, ok: true),
            entry("b", dryRun: true, ok: false),
            entry("c", dryRun: false, ok: true),
            entry("d", dryRun: false, ok: false),
        ])
        XCTAssertEqual(rows[1][4], "yes"); XCTAssertEqual(rows[1][5], "ok")
        XCTAssertEqual(rows[2][4], "yes"); XCTAssertEqual(rows[2][5], "failed")
        XCTAssertEqual(rows[3][4], "no");  XCTAssertEqual(rows[3][5], "ok")
        XCTAssertEqual(rows[4][4], "no");  XCTAssertEqual(rows[4][5], "failed")
    }

    func testTheTimestampRendersAsAReadableISO8601String() {
        let rows = MaintenanceCmd.History.rows(for: [entry("admin@example.com", dryRun: false, ok: true)])
        XCTAssertEqual(rows[1][0], "2025-08-24T13:20:00Z")
    }

    func testIdentityActionParamsAndMessageAreCarriedThroughVerbatim() {
        let rows = MaintenanceCmd.History.rows(for: [
            entry("admin@example.com", action: "reboot", params: #"{"mode": "reboot"}"#,
                 dryRun: false, ok: false, message: "sudo: a password is required"),
        ])
        let row = rows[1]
        XCTAssertEqual(row[1], "admin@example.com")
        XCTAssertEqual(row[2], "reboot")
        XCTAssertEqual(row[3], #"{"mode": "reboot"}"#)
        XCTAssertEqual(row[6], "sudo: a password is required")
    }
}
