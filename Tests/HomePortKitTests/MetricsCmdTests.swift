import XCTest
import HomePortKit
@testable import hpm

/// `hpm metrics`'s own two decisions: what `--range` accepts, and the exact shape of the
/// table it prints. Everything else the command does belongs to `HomeportMetricsReader`,
/// which `ManagerMetricsTests` covers.
final class MetricsCmdTests: XCTestCase {

    // MARK: --range

    func testTheDefaultRangeIsTheContractsOwn() throws {
        XCTAssertEqual(try MetricsCmd.parseRangeOption(nil), .h24)
    }

    func testTheFourDocumentedRangesAreAccepted() throws {
        for range in MetricsRange.allCases {
            XCTAssertEqual(try MetricsCmd.parseRangeOption(range.rawValue), range)
        }
        XCTAssertEqual(try MetricsCmd.parseRangeOption("30D"), .d30,
                       "a range typed in capitals is the same range")
    }

    /// A range outside the four is a typo on the command line, not a value served by a
    /// machine: the contract's own answer to an unknown range is a 400 (§7), and there is no
    /// neighbouring value to clamp to. The message names all four so the user does not have
    /// to guess which one they meant.
    func testAnUnknownRangeFailsNamingTheFourAccepted() {
        XCTAssertThrowsError(try MetricsCmd.parseRangeOption("3h")) { error in
            let message = "\(error)"
            for range in MetricsRange.allCases {
                XCTAssertTrue(message.contains(range.rawValue), "\(range.rawValue) missing from: \(message)")
            }
        }
    }

    // MARK: The table

    private func window(cpu: [Double?], temp: [Double?]) -> MetricsWindow {
        MetricsWindow(epoch: "e", range: .h24, stepS: 60,
                      from: Date(timeIntervalSince1970: 1_756_041_600),
                      to: Date(timeIntervalSince1970: 1_756_041_600 + 60 * Double(cpu.count)),
                      cpu: MetricSeries(kind: .cpu, points: cpu),
                      memory: MetricSeries(kind: .memory, points: [41.2, 41.3, 41.1]),
                      disk: MetricSeries(kind: .disk, points: [67, 67, 67]),
                      temperature: MetricSeries(kind: .temperature, points: temp))
    }

    /// Five columns, newest first, one line per grid slot — the same content as the curve,
    /// which is what FR11 asks of a CLI twin.
    func testTheTableIsFiveColumnsNewestFirst() {
        let rows = MetricsCmd.rows(for: window(cpu: [12.4, 13.0, 11.8], temp: [48.5, 49.0, 47.9]))
        XCTAssertEqual(rows.first, ["DATE", "CPU%", "MEM%", "DISK%", "TEMP°C"])
        XCTAssertEqual(rows.count, 4, "the header plus one line per grid slot")
        XCTAssertEqual(rows[1], ["2025-08-24T13:22:00Z", "11.8", "41.1", "67.0", "47.9"],
                       "the most recent slot comes first")
        XCTAssertEqual(rows[3], ["2025-08-24T13:20:00Z", "12.4", "41.2", "67.0", "48.5"])
    }

    /// §7: a null is an absence, not a zero. The table says so with a marker, and never with
    /// a number a reader could average.
    func testAnAbsentMeasurementPrintsAMarkerRatherThanAZero() {
        let rows = MetricsCmd.rows(for: window(cpu: [1.0, nil, 2.0], temp: [nil, nil, nil]))
        XCTAssertEqual(rows[2][1], "-", "the hole in the middle of cpu_pct")
        XCTAssertEqual(rows.dropFirst().map { $0[4] }, ["-", "-", "-"],
                       "a machine with no thermal sensor still gets its column")
    }

    /// The header is what makes 1 440 lines predictable before they unroll — and it states
    /// the grid *as served*, since that is what the instants above were computed from.
    func testTheHeaderAnnouncesTheServedGrid() {
        let header = MetricsCmd.header(for: window(cpu: [1, 2, 3], temp: [1, 2, 3]))
        XCTAssertTrue(header.contains("range 24h"), header)
        XCTAssertTrue(header.contains("step 60s"), header)
        XCTAssertTrue(header.contains("from 2025-08-24T13:20:00Z"), header)
        XCTAssertTrue(header.contains("to 2025-08-24T13:23:00Z"), header)
        XCTAssertTrue(header.contains("points 3"), header)
    }
}
