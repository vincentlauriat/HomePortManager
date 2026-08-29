import XCTest
@testable import HomePortKit

/// The metrics half of the v1 contract (§7 and §8), tested through the production decoding
/// and classification: only the HTTP exchange is replaced.
///
/// The point of these fixtures is that the *body* decides. §7 says the served grid is what
/// makes the instants, and §8 says an announced-but-discordant surface is never a
/// breakdown — so every incoherent grid below has to come out as `surfaceNotServed`, and
/// none of them as `unreachable`.
final class HomeportAPIMetricsTests: XCTestCase {
    private let machine = Machine(name: "raspcorse", ssh: "raspcorse", port: 80)

    private func client(_ reply: @escaping (URL) throws -> HTTPReply) -> HomeportAPIClient {
        HomeportAPIClient(fetch: { url in try reply(url) })
    }

    private func ok(_ json: String) -> HTTPReply {
        HTTPReply(status: 200, body: Data(json.utf8))
    }

    /// §7's own example, verbatim — four points per series, `from`/`to` narrowed to match
    /// (the document abbreviates the arrays and keeps the day-wide bounds of a real 24 h
    /// window, which its own length rule would then reject).
    private let metricsJSON = """
    {
      "epoch": "0f8a4c2e-9d51-4b77-b3a0-6c1d2e5f8a90",
      "range": "24h",
      "step_s": 60,
      "from": 1755955200,
      "to": 1755955440,
      "series": {
        "cpu_pct":  [12.4, 13.0, null, 11.8],
        "mem_pct":  [41.2, 41.3, null, 41.1],
        "disk_pct": [67.0, 67.0, null, 67.0],
        "temp_c":   [48.5, 49.0, null, 47.9]
      }
    }
    """

    private func window(_ json: String) async -> MetricsWindow? {
        let client = client { _ in self.ok(json) }
        guard case .window(let window) = await client.metrics(of: machine, range: .h24) else {
            return nil
        }
        return window
    }

    private func unavailable(_ json: String) async -> APIUnavailableReason? {
        let client = client { _ in self.ok(json) }
        guard case .unavailable(let reason) = await client.metrics(of: machine, range: .h24) else {
            return nil
        }
        return reason
    }

    // MARK: The nominal window

    func testTheDocumentsOwnPayloadDecodesOntoTheServedGrid() async throws {
        let served = await window(metricsJSON)
        let window = try XCTUnwrap(served)
        XCTAssertEqual(window.epoch, "0f8a4c2e-9d51-4b77-b3a0-6c1d2e5f8a90")
        XCTAssertEqual(window.range, .h24)
        XCTAssertEqual(window.stepS, 60)
        XCTAssertEqual(window.from, Date(timeIntervalSince1970: 1755955200))
        XCTAssertEqual(window.to, Date(timeIntervalSince1970: 1755955440))
        XCTAssertEqual(window.pointCount, 4)
        XCTAssertEqual(window.series.map(\.kind), [.cpu, .memory, .disk, .temperature],
                       "the four series come out in the order both surfaces show them")
        XCTAssertEqual(window.cpu.points, [12.4, 13.0, nil, 11.8],
                       "a null stays an absence — never a zero (§7)")
        XCTAssertEqual(window.temperature.current, 47.9)
    }

    /// §7: the instant of point `i` is `from + i * step_s`, from the served grid and nothing
    /// else. No table of ranges to steps exists anywhere in the client, so a server serving
    /// `24h` on a five-second step is followed rather than corrected.
    func testTheInstantOfAPointComesFromTheServedGridNotFromATable() async throws {
        let json = """
        {"epoch": "e", "range": "24h", "step_s": 5, "from": 1000, "to": 1020,
         "series": {"cpu_pct": [1, 2, 3, 4], "mem_pct": [1, 2, 3, 4],
                    "disk_pct": [1, 2, 3, 4], "temp_c": [1, 2, 3, 4]}}
        """
        let served = await self.window(json)
        let window = try XCTUnwrap(served)
        XCTAssertEqual(window.stepS, 5)
        XCTAssertEqual(window.timestamp(at: 0), Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(window.timestamp(at: 3), Date(timeIntervalSince1970: 1015))
    }

    /// §7: a series a machine cannot produce is present with every point at null. A body
    /// that omits it altogether says the same thing, and the client must still show four
    /// cards — an empty one rather than a missing one.
    func testASeriesAbsentFromTheBodyComesOutEntirelyNull() async throws {
        let json = """
        {"epoch": "e", "range": "24h", "step_s": 60, "from": 0, "to": 240,
         "series": {"cpu_pct": [1, 2, 3, 4], "mem_pct": [1, 2, 3, 4], "disk_pct": [1, 2, 3, 4]}}
        """
        let served = await self.window(json)
        let window = try XCTUnwrap(served)
        XCTAssertEqual(window.series.count, 4, "four cards, always")
        XCTAssertEqual(window.temperature.points, [nil, nil, nil, nil])
        XCTAssertNil(window.temperature.current)
        XCTAssertTrue(window.temperature.segments.isEmpty, "nothing to draw, and no error")
    }

    /// §7: a client of the v1.0 ignores a key of `series` it does not know — a series added
    /// by a later minor must not become a fifth card, nor make the window fail.
    func testAnUnknownSeriesIsIgnoredWithoutError() async throws {
        let json = """
        {"epoch": "e", "range": "24h", "step_s": 60, "from": 0, "to": 240,
         "series": {"cpu_pct": [1, 2, 3, 4], "mem_pct": [1, 2, 3, 4],
                    "disk_pct": [1, 2, 3, 4], "temp_c": [1, 2, 3, 4],
                    "net_rx_bps": [9, 9]}}
        """
        let served = await self.window(json)
        let window = try XCTUnwrap(served)
        XCTAssertEqual(window.series.map(\.kind), [.cpu, .memory, .disk, .temperature])
        XCTAssertEqual(window.pointCount, 4,
                       "the unknown key is ignored — including its length, which fits no grid")
    }

    // MARK: The query

    func testTheRequestCarriesTheRangeAndNothingElse() async {
        let asked = Sent()
        let client = client { url in
            asked.url = url
            return self.ok(self.metricsJSON)
        }
        _ = await client.metrics(of: machine, range: .d30)
        let query = URLComponents(url: asked.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
        XCTAssertEqual(asked.url?.path, "/api/v1/metrics")
        XCTAssertEqual(query.map(\.name), ["range"], "the contract has exactly one parameter (§7)")
        XCTAssertEqual(query.first?.value, "30d")
    }

    /// A box the closure can write into: the fetch seam is `@Sendable`, and the assertions
    /// need what it was asked for.
    private final class Sent: @unchecked Sendable { var url: URL? }

    // MARK: An incoherent grid is a discordant surface, never a breakdown (§8)

    func testAGridWhoseSpanIsNotAMultipleOfTheStepIsNotServed() async {
        let json = """
        {"epoch": "e", "range": "24h", "step_s": 60, "from": 0, "to": 250,
         "series": {"cpu_pct": [1, 2, 3, 4], "mem_pct": [1, 2, 3, 4],
                    "disk_pct": [1, 2, 3, 4], "temp_c": [1, 2, 3, 4]}}
        """
        let reason = await unavailable(json)
        XCTAssertEqual(reason, .surfaceNotServed("metrics"))
    }

    func testANonPositiveStepIsNotServed() async {
        let json = """
        {"epoch": "e", "range": "24h", "step_s": 0, "from": 0, "to": 240,
         "series": {"cpu_pct": [], "mem_pct": [], "disk_pct": [], "temp_c": []}}
        """
        let reason = await unavailable(json)
        XCTAssertEqual(reason, .surfaceNotServed("metrics"))
    }

    func testAWindowThatDoesNotMoveForwardIsNotServed() async {
        let json = """
        {"epoch": "e", "range": "24h", "step_s": 60, "from": 240, "to": 240,
         "series": {"cpu_pct": [], "mem_pct": [], "disk_pct": [], "temp_c": []}}
        """
        let reason = await unavailable(json)
        XCTAssertEqual(reason, .surfaceNotServed("metrics"))
    }

    func testAKnownSeriesOfTheWrongLengthIsNotServed() async {
        let json = """
        {"epoch": "e", "range": "24h", "step_s": 60, "from": 0, "to": 240,
         "series": {"cpu_pct": [1, 2, 3], "mem_pct": [1, 2, 3, 4],
                    "disk_pct": [1, 2, 3, 4], "temp_c": [1, 2, 3, 4]}}
        """
        let reason = await unavailable(json)
        XCTAssertEqual(reason, .surfaceNotServed("metrics"),
                       "§7 makes the length unambiguous: a series that misses it is not the contract's")
    }

    /// A body announcing a one-second step over a year would have the client materialise a
    /// billion slots for every absent series before anything could reject it. The ceiling is
    /// a guard on allocation, not a step table: no range is ever compared to 60 or 86400.
    func testAnAbsurdlyLongGridIsNotServed() async {
        let json = """
        {"epoch": "e", "range": "1y", "step_s": 1, "from": 0, "to": 31536000, "series": {}}
        """
        let reason = await unavailable(json)
        XCTAssertEqual(reason, .surfaceNotServed("metrics"))
    }

    func testARangeTheContractDoesNotDefineIsNotServed() async {
        let json = """
        {"epoch": "e", "range": "3h", "step_s": 60, "from": 0, "to": 240,
         "series": {"cpu_pct": [1, 2, 3, 4], "mem_pct": [1, 2, 3, 4],
                    "disk_pct": [1, 2, 3, 4], "temp_c": [1, 2, 3, 4]}}
        """
        let reason = await unavailable(json)
        XCTAssertEqual(reason, .surfaceNotServed("metrics"))
    }

    /// §7: "a table contains only numbers and nulls — never a string." A string is therefore
    /// a body that is not the contract's, not a value to fold.
    func testABodyThatIsNotTheContractsIsNotServed() async {
        let garbage = await unavailable(#"{"hello": "world"}"#)
        XCTAssertEqual(garbage, .surfaceNotServed("metrics"))
        let stringy = """
        {"epoch": "e", "range": "24h", "step_s": 60, "from": 0, "to": 120,
         "series": {"cpu_pct": ["12.4", null], "mem_pct": [1, 2],
                    "disk_pct": [1, 2], "temp_c": [1, 2]}}
        """
        let reason = await unavailable(stringy)
        XCTAssertEqual(reason, .surfaceNotServed("metrics"))
    }

    // MARK: What the status code concludes (§8)

    /// §8: a surface announced in `features` that answers 404 is treated exactly like one
    /// absent from it — never as a breakdown.
    func testA404OnAnAnnouncedSurfaceIsNotAFailure() async {
        let client = client { _ in HTTPReply(status: 404, body: Data()) }
        guard case .unavailable(let reason) = await client.metrics(of: machine, range: .h24) else {
            return XCTFail("a 404 on metrics is 'not served', never 'unreachable'")
        }
        XCTAssertEqual(reason, .surfaceNotServed("metrics"))
    }

    /// §8: a 400 means the server does not know a range of the v1 — the remedy is an update,
    /// and the contract forbids retrying the call as-is. `unreachable` would retry it for
    /// ever, so the classification has to be the same one an unserved surface gets.
    func testARefusedRangeSendsTheUserToAnUpdateRatherThanRetryingForEver() async {
        let client = client { _ in HTTPReply(status: 400, body: Data(#"{"error":"bad range"}"#.utf8)) }
        guard case .unavailable(let reason) = await client.metrics(of: machine, range: .y1) else {
            return XCTFail("a 400 is a client-side mistake the contract answers with an update")
        }
        XCTAssertEqual(reason, .surfaceNotServed("metrics"))
    }

    /// §8: 5xx is "retry later, invalidate nothing" — the one row that keeps the curves on
    /// screen under an "unreachable" banner.
    func testAServerFailureIsUnreachable() async {
        let client = client { _ in HTTPReply(status: 503, body: Data()) }
        guard case .unreachable(let detail) = await client.metrics(of: machine, range: .h24) else {
            return XCTFail("a 5xx is unreachable, not unavailable")
        }
        XCTAssertEqual(detail, "HTTP 503")
    }

    func testANetworkErrorIsUnreachableAndCarriesItsCode() async {
        let client = client { _ in throw URLError(.cannotConnectToHost) }
        guard case .unreachable(let detail) = await client.metrics(of: machine, range: .h24) else {
            return XCTFail("a network error is unreachable")
        }
        XCTAssertTrue(detail.contains("\(URLError.cannotConnectToHost.rawValue)"), detail)
    }

    /// A cancelled fetch is the caller's own task going away — a tab switch mid-read — and
    /// must never be applied as a verdict about the machine.
    func testACancelledFetchIsDistinctFromUnreachable() async {
        for error in [CancellationError() as Error, URLError(.cancelled)] {
            let client = client { _ in throw error }
            let outcome = await client.metrics(of: machine, range: .h24)
            XCTAssertEqual(outcome, .cancelled)
        }
    }
}
