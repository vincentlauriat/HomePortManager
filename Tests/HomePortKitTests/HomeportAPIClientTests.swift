import XCTest
@testable import HomePortKit

/// The client half of the v1 contract, tested against fixtures shaped exactly like the
/// examples in `docs/api/homeport-api-v1.md`.
///
/// This is the link story 2.1 could not close: until now a single line of that document —
/// the consumed version range — was bound to anything executable, and every other rule
/// (the severity mapping, the conduct of §8, the shape of a response) was prose nothing
/// could contradict. These tests decode the document's own payloads through the production
/// code path: only the HTTP exchange is replaced.
final class HomeportAPIClientTests: XCTestCase {
    private let machine = Machine(name: "raspcorse", ssh: "raspcorse", port: 80)

    /// A client whose network is a lookup table. The URL is handed back so the assertions
    /// can also pin what was *asked* — the query is half the contract in §6.
    private func client(_ reply: @escaping (URL) throws -> HTTPReply) -> HomeportAPIClient {
        HomeportAPIClient(fetch: { url in try reply(url) })
    }

    private func ok(_ json: String) -> HTTPReply {
        HTTPReply(status: 200, body: Data(json.utf8))
    }

    /// §4's own example, verbatim.
    private let capabilitiesJSON = """
    {
      "contract": "1.0.0",
      "server": "0.8.0",
      "epoch": "0f8a4c2e-9d51-4b77-b3a0-6c1d2e5f8a90",
      "features": ["events", "metrics"]
    }
    """

    /// §6's own example, verbatim.
    private let eventsJSON = """
    {
      "epoch": "0f8a4c2e-9d51-4b77-b3a0-6c1d2e5f8a90",
      "latest_id": 1483,
      "events": [
        {
          "id": 1482,
          "ts": 1756041600,
          "kind": "service.down",
          "severity": "critical",
          "subject": "homeassistant",
          "detail": null
        },
        {
          "id": 1483,
          "ts": 1756041615,
          "kind": "backup.ok",
          "severity": "info",
          "subject": "homeassistant",
          "detail": "homeassistant-2026-08-24.tar.gz"
        }
      ],
      "has_more": false
    }
    """

    // MARK: The handshake (§4)

    func testTheDocumentedCapabilitiesExampleDecodes() async {
        let client = client { _ in self.ok(self.capabilitiesJSON) }
        guard case .available(let capabilities) = await client.capabilities(of: machine) else {
            return XCTFail("the contract's own example must be a successful handshake")
        }
        XCTAssertEqual(capabilities.contract, SemanticVersion(1, 0, 0))
        XCTAssertEqual(capabilities.server, "0.8.0")
        XCTAssertEqual(capabilities.epoch, "0f8a4c2e-9d51-4b77-b3a0-6c1d2e5f8a90")
        XCTAssertEqual(capabilities.features, ["events", "metrics"])
        XCTAssertTrue(capabilities.serves("events"))
        XCTAssertFalse(capabilities.serves("logs"), "an unknown surface is simply absent")
    }

    func testCapabilitiesIsAskedAtTheVersionedPath() async {
        var asked: URL?
        let client = client { url in
            asked = url
            return self.ok(self.capabilitiesJSON)
        }
        _ = await client.capabilities(of: machine)
        XCTAssertEqual(asked?.absoluteString, "http://raspcorse:80/api/v1/capabilities")
    }

    // MARK: §8, row by row

    /// Row 1: a Homeport older than the API answers 404 — a normal, expected state.
    func testA404OnCapabilitiesIsUnavailableNotAnError() async {
        let client = client { _ in HTTPReply(status: 404, body: Data()) }
        let verdict = await client.capabilities(of: machine)
        XCTAssertEqual(verdict, .unavailable(.notServed))
    }

    /// Row 2: out of the consumed range, and the verdict names the version met.
    func testAContractOutsideTheConsumedRangeIsUnavailableAndNamesTheVersion() async {
        for (raw, expected) in [("2.0.0", ContractCompatibility.tooNew(SemanticVersion(2, 0, 0))),
                                ("0.9.0", .tooOld(SemanticVersion(0, 9, 0))),
                                ("1.1.0-rc1", .preRelease("1.1.0-rc1")),
                                ("nonsense", .unreadable("nonsense"))] {
            let client = client { _ in
                self.ok("""
                {"contract": "\(raw)", "server": "0.8.0", "epoch": "e", "features": ["events"]}
                """)
            }
            let verdict = await client.capabilities(of: machine)
            XCTAssertEqual(verdict, .unavailable(.incompatibleContract(expected)),
                           "contract \(raw) must be reported, not thrown")
        }
    }

    /// §4: a handshake missing a required field, or carrying one of the wrong type, is
    /// treated *exactly* like a 404. A client never guesses a missing field.
    func testAMalformedHandshakeIsTreatedExactlyLikeA404() async {
        let bodies = [
            #"{"server": "0.8.0", "epoch": "e", "features": ["events"]}"#,          // no contract
            #"{"contract": "1.0.0", "server": "0.8.0", "features": ["events"]}"#,   // no epoch
            #"{"contract": "1.0.0", "server": "0.8.0", "epoch": "e"}"#,             // no features
            #"{"contract": 1, "epoch": "e", "features": ["events"]}"#,              // wrong type
            #"{"contract": "1.0.0", "epoch": "e", "features": "events"}"#,          // wrong type
            "not json at all",
            "",
        ]
        for body in bodies {
            let client = client { _ in self.ok(body) }
            let verdict = await client.capabilities(of: machine)
            XCTAssertEqual(verdict, .unavailable(.notServed),
                           "\(body.debugDescription) is not a handshake")
        }
    }

    /// `server` is informational (§9) and its absence must not sink the handshake.
    func testAHandshakeWithoutServerStillCompletes() async {
        let client = client { _ in
            self.ok(#"{"contract": "1.0.0", "epoch": "e", "features": ["events"]}"#)
        }
        guard case .available(let capabilities) = await client.capabilities(of: machine) else {
            return XCTFail("only contract, epoch and features are required")
        }
        XCTAssertNil(capabilities.server)
    }

    /// Row 3: the surface is not announced. The client does not probe the endpoint to
    /// find out — it reads `features` (§4) — so this verdict is the reader's, and the
    /// client's job is only to report a `features` list that omits it.
    func testAnInstanceCanServeTheContractWithoutServingEvents() async {
        let client = client { _ in
            self.ok(#"{"contract": "1.0.0", "epoch": "e", "features": ["metrics"]}"#)
        }
        guard case .available(let capabilities) = await client.capabilities(of: machine) else {
            return XCTFail("a partial instance still completes the handshake")
        }
        XCTAssertFalse(capabilities.serves("events"))
        XCTAssertTrue(capabilities.serves("metrics"), "the other surface is untouched")
    }

    /// Row 4: a network error is `unreachable`, never `unavailable` — the two are resolved
    /// at opposite ends, and confounding them sends the user to the wrong place.
    func testANetworkErrorIsUnreachableAndCarriesItsDescription() async {
        let client = client { _ in throw URLError(.timedOut) }
        guard case .unreachable(let detail) = await client.capabilities(of: machine) else {
            return XCTFail("a timeout is unreachable, not unavailable")
        }
        XCTAssertTrue(detail.contains("\(URLError.timedOut.rawValue)"),
                      "the code makes two identical descriptions tellable apart: \(detail)")
    }

    /// A cancelled fetch — the caller's own task went away, e.g. a tab switch mid-read —
    /// must not be reported the same way as a real network failure: `EventFeed` must
    /// never persist a false "injoignable" over a feed that survives the cancelling task.
    func testACancelledFetchIsDistinctFromUnreachable() async {
        let client = client { _ in throw CancellationError() }
        let capabilitiesVerdict = await client.capabilities(of: machine)
        XCTAssertEqual(capabilitiesVerdict, .cancelled)
        let eventsVerdict = await client.events(of: machine, sinceID: 0, sinceEpoch: nil, limit: 200)
        XCTAssertEqual(eventsVerdict, .cancelled)
    }

    /// `URLSession` can also surface a cancellation as `URLError.cancelled` rather than
    /// `CancellationError`, depending on when it lands — both must be recognised.
    func testAURLErrorCancelledIsAlsoDistinguishedFromUnreachable() async {
        let client = client { _ in throw URLError(.cancelled) }
        let verdict = await client.capabilities(of: machine)
        XCTAssertEqual(verdict, .cancelled)
    }

    /// Row 7: 5xx is "retry later, invalidate nothing" — the same state as unreachable.
    func testAServerFailureIsUnreachable() async {
        for status in [500, 502, 503] {
            let client = client { _ in HTTPReply(status: status, body: Data()) }
            let verdict = await client.capabilities(of: machine)
            XCTAssertEqual(verdict, .unreachable("HTTP \(status)"))
        }
    }

    /// Row 5: announced in `features` and answering 404 is folded into "not served" —
    /// never a breakdown.
    func testAnAnnouncedEventsSurfaceThatAnswers404IsNotServedNotBroken() async {
        let client = client { _ in HTTPReply(status: 404, body: Data()) }
        let verdict = await client.events(of: machine, sinceID: 0, sinceEpoch: nil, limit: 200)
        XCTAssertEqual(verdict, .unavailable(.surfaceNotServed("events")))
    }

    /// The same conclusion for a 200 whose body is not the documented shape: an
    /// announcement that does not match the service, which §8 says is never a breakdown.
    func testAnUndecodableEventsBodyIsNotServedNotBroken() async {
        for body in ["{}", "[]", #"{"epoch": "e", "latest_id": 3, "has_more": false}"#, "nope"] {
            let client = client { _ in self.ok(body) }
            let verdict = await client.events(of: machine, sinceID: 0, sinceEpoch: nil, limit: 200)
            XCTAssertEqual(verdict, .unavailable(.surfaceNotServed("events")),
                           "\(body.debugDescription) is not an events page")
        }
    }

    // MARK: The events payload (§6)

    func testTheDocumentedEventsExampleDecodes() async {
        let client = client { _ in self.ok(self.eventsJSON) }
        guard case .page(let page) = await client.events(of: machine, sinceID: 1481,
                                                         sinceEpoch: nil, limit: 200) else {
            return XCTFail("the contract's own example must decode")
        }
        XCTAssertEqual(page.epoch, "0f8a4c2e-9d51-4b77-b3a0-6c1d2e5f8a90")
        XCTAssertEqual(page.latestID, 1483)
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(page.events.map(\.id), [1482, 1483], "served oldest first, kept that way")
        XCTAssertEqual(page.events[0].severity, .critical)
        XCTAssertEqual(page.events[0].kind, "service.down")
        XCTAssertEqual(page.events[0].subject, "homeassistant")
        XCTAssertNil(page.events[0].detail, "a null detail is an absence, not an empty string")
        XCTAssertEqual(page.events[0].timestamp, Date(timeIntervalSince1970: 1_756_041_600))
        XCTAssertEqual(page.events[1].severity, .info)
        XCTAssertEqual(page.events[1].detail, "homeassistant-2026-08-24.tar.gz")
    }

    /// §6: an unknown severity is `warning` — visible without notifying. Folding it to
    /// `info` would hide it; to `critical` it would wake someone for nothing.
    func testAnUnknownSeverityBecomesWarning() async {
        let client = client { _ in
            self.ok("""
            {"epoch": "e", "latest_id": 2, "has_more": false, "events": [
              {"id": 1, "ts": 1, "kind": "temp.high", "severity": "fatal", "subject": "cpu", "detail": null},
              {"id": 2, "ts": 2, "kind": "boot", "severity": "", "subject": "system", "detail": null}
            ]}
            """)
        }
        guard case .page(let page) = await client.events(of: machine, sinceID: 0,
                                                         sinceEpoch: nil, limit: 200) else {
            return XCTFail("an unknown severity must not sink the page")
        }
        XCTAssertEqual(page.events.map(\.severity), [.warning, .warning])
        XCTAssertEqual(page.events[0].severity.displaySeverity, .warning,
                       "it stays visible in the pill — never invisible")
    }

    /// The mapping onto the app's single pill. `info` → `ok` is the one that matters: it
    /// is what lets the Events tab reuse `StatusPill` instead of growing a second one.
    func testSeveritiesMapOntoTheOnePillTheAppHas() {
        XCTAssertEqual(EventSeverity.info.displaySeverity, .ok)
        XCTAssertEqual(EventSeverity.warning.displaySeverity, .warning)
        XCTAssertEqual(EventSeverity.critical.displaySeverity, .critical)
    }

    /// §6 says the list of `kind` is open, and §9 forbids assuming otherwise: an unknown
    /// one is displayed as served, with its family available only for grouping.
    func testAnUnknownKindIsCarriedThroughUntouched() async {
        let client = client { _ in
            self.ok("""
            {"epoch": "e", "latest_id": 1, "has_more": false, "events": [
              {"id": 1, "ts": 1, "kind": "device.new", "severity": "warning",
               "subject": "c0:95:6d:9f:a6:d5", "detail": "192.168.100.51"}
            ]}
            """)
        }
        guard case .page(let page) = await client.events(of: machine, sinceID: 0,
                                                         sinceEpoch: nil, limit: 200) else {
            return XCTFail("an unknown kind must decode like any other")
        }
        XCTAssertEqual(page.events[0].kind, "device.new")
        XCTAssertEqual(page.events[0].family, "device")
        XCTAssertEqual(HomeportEvent(id: 1, timestamp: .distantPast, kind: "boot",
                                     severity: .warning, subject: "system", detail: nil).family,
                       "boot", "a kind without a family is its own family")
    }

    // MARK: The query (§6)

    func testTheQueryCarriesTheCursorAndClampsTheLimit() async {
        var asked: URL?
        let client = client { url in
            asked = url
            return self.ok(self.eventsJSON)
        }
        _ = await client.events(of: machine, sinceID: 1481, sinceEpoch: "abc", limit: 5000)
        let items = URLComponents(string: asked?.absoluteString ?? "")?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "since_id" }?.value, "1481")
        XCTAssertEqual(items.first { $0.name == "since_epoch" }?.value, "abc")
        XCTAssertEqual(items.first { $0.name == "limit" }?.value, "1000",
                       "the ceiling is the contract's, and the client respects it itself")
        XCTAssertEqual(asked?.path, "/api/v1/events")
    }

    func testAnAbsentCursorEpochIsOmittedFromTheQuery() async {
        var asked: URL?
        let client = client { url in
            asked = url
            return self.ok(self.eventsJSON)
        }
        _ = await client.events(of: machine, sinceID: 0, sinceEpoch: nil, limit: 0)
        let items = URLComponents(string: asked?.absoluteString ?? "")?.queryItems ?? []
        XCTAssertNil(items.first { $0.name == "since_epoch" },
                     "since_epoch is optional (§6); an empty one would be a lie about the cursor")
        XCTAssertEqual(items.first { $0.name == "limit" }?.value, "1", "the floor is clamped too")
    }

    // MARK: An address that cannot exist

    /// A fleet.yaml identity from which no address can be derived is neither "too old" —
    /// which would send the user to Updates, the wrong place — nor a healthy machine.
    func testAnUndeliverableAddressIsUnreachableRatherThanUnavailable() async {
        let broken = Machine(name: "broken", ssh: "user@", port: 80)
        let client = client { _ in XCTFail("no request should be made"); return self.ok("{}") }
        guard case .unreachable(let detail) = await client.capabilities(of: broken) else {
            return XCTFail("an underivable address must not be reported as an outdated Homeport")
        }
        XCTAssertTrue(detail.contains("broken"))
        guard case .unreachable = await client.events(of: broken, sinceID: 0,
                                                      sinceEpoch: nil, limit: 200) else {
            return XCTFail("same conclusion on the events surface")
        }
    }
}
