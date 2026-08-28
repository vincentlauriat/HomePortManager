import XCTest
@testable import HomePortKit

/// The reader that both the Events tab and `hpm events` go through: the cursor, its two
/// invalidation conditions (§5), the pagination that must never stop on the oldest events
/// of a long epoch (§6), and the window that comes out.
final class ManagerEventsTests: XCTestCase {
    private let machine = Machine(name: "raspcorse", ssh: "raspcorse", port: 80)

    // MARK: Doubles

    /// A history that answers like the contract says a server must: ascending by `id`,
    /// `latest_id` independent of `limit`, `has_more` telling the truth. Records every
    /// request so the pagination itself can be asserted, not only its result.
    private final class FakeAPI: HomeportEventsReading, @unchecked Sendable {
        var features: [String] = ["events", "metrics"]
        var contract = "1.0.0"
        var epoch: String
        var events: [HomeportEvent]
        /// Overrides the `latest_id` the pages announce — how a restored, shorter history
        /// is staged without also rewriting `events`.
        var announcedLatestID: Int64?
        var handshake: APIAvailability?
        var pageOutcome: EventsPageOutcome?
        private(set) var requests: [(sinceID: Int64, sinceEpoch: String?, limit: Int)] = []

        init(epoch: String = "epoch-1", events: [HomeportEvent] = []) {
            self.epoch = epoch
            self.events = events
        }

        func capabilities(of machine: Machine) async -> APIAvailability {
            if let handshake { return handshake }
            guard case .compatible(let version) = HomeportAPIContract.compatibility(with: contract) else {
                return .unavailable(.incompatibleContract(HomeportAPIContract.compatibility(with: contract)))
            }
            return .available(HomeportCapabilities(contract: version, server: "0.8.0",
                                                   epoch: epoch, features: features))
        }

        func events(of machine: Machine, sinceID: Int64, sinceEpoch: String?,
                    limit: Int) async -> EventsPageOutcome {
            requests.append((sinceID, sinceEpoch, limit))
            if let pageOutcome { return pageOutcome }
            // §6: a `since_epoch` that does not match the current one is not an error —
            // the server serves from the beginning and announces its own epoch.
            let from = (sinceEpoch == nil || sinceEpoch == epoch) ? sinceID : 0
            let after = events.filter { $0.id > from }
            let slice = Array(after.prefix(limit))
            return .page(EventPage(epoch: epoch,
                                   latestID: announcedLatestID ?? (events.last?.id ?? 0),
                                   events: slice,
                                   hasMore: slice.count < after.count))
        }
    }

    private final class MemoryCursors: EventCursorStore, @unchecked Sendable {
        var stored: [String: EventCursor] = [:]
        private(set) var writes = 0

        func eventCursor(machine: String) throws -> EventCursor? { stored[machine] }

        func setEventCursor(_ cursor: EventCursor, machine: String, now: Date) throws {
            stored[machine] = cursor
            writes += 1
        }
    }

    private func history(_ ids: ClosedRange<Int64>, severity: EventSeverity = .info) -> [HomeportEvent] {
        ids.map {
            HomeportEvent(id: $0, timestamp: Date(timeIntervalSince1970: TimeInterval($0)),
                          kind: "service.up", severity: severity, subject: "homeassistant",
                          detail: nil)
        }
    }

    private func window(_ read: EventsRead, _ message: String = "", file: StaticString = #filePath,
                        line: UInt = #line) -> EventWindow? {
        guard case .window(let window) = read else {
            XCTFail("expected a window, got \(read). \(message)", file: file, line: line)
            return nil
        }
        return window
    }

    // MARK: Pagination past `limit` — the bug this story was split out of

    /// The contract offers no "give me the most recent" query: only an ascending pull.
    /// Stopping at the first page would pin the display to the *oldest* events of any epoch
    /// longer than `limit`, silently. The read pages to `has_more == false` and keeps the tail.
    func testAnEpochLongerThanTheLimitShowsItsMostRecentWindow() async {
        let api = FakeAPI(events: history(1...1000))
        let reader = HomeportEventsReader(api: api)

        guard let window = window(await reader.read(machine, mode: .window, limit: 200)) else { return }
        XCTAssertEqual(window.events.count, 200)
        XCTAssertEqual(window.events.first?.id, 801)
        XCTAssertEqual(window.events.last?.id, 1000,
                       "the newest event must be on screen — never stuck on the oldest")
        XCTAssertEqual(window.latestID, 1000)
        XCTAssertEqual(api.requests.map(\.sinceID), [0, 200, 400, 600, 800],
                       "one request per page, each starting where the previous ended; the fifth "
                       + "exhausts the history and clears has_more, so no sixth is made")
    }

    func testAShortHistoryIsReadInOnePage() async {
        let api = FakeAPI(events: history(1...12))
        guard let window = window(await HomeportEventsReader(api: api).read(machine, limit: 200))
        else { return }
        XCTAssertEqual(window.events.map(\.id), Array(1...12))
        XCTAssertEqual(api.requests.count, 1, "has_more was false; nothing more to ask")
    }

    func testAnEmptyHistoryIsAWindowWithNoEventsNotAFailure() async {
        let api = FakeAPI(events: [])
        guard let window = window(await HomeportEventsReader(api: api).read(machine)) else { return }
        XCTAssertTrue(window.events.isEmpty)
        XCTAssertEqual(window.latestID, 0)
        XCTAssertFalse(window.cursorWasReset)
    }

    /// A server that keeps `has_more` true while serving nothing new would otherwise spin
    /// the poll forever. Forward progress is the loop's own condition.
    func testAPageThatCannotAdvanceStopsTheRead() async {
        let api = FakeAPI(events: history(1...5))
        api.pageOutcome = .page(EventPage(epoch: "epoch-1", latestID: 5, events: [], hasMore: true))
        guard let window = window(await HomeportEventsReader(api: api).read(machine)) else { return }
        XCTAssertTrue(window.events.isEmpty)
        XCTAssertEqual(api.requests.count, 1, "a page that advances nothing is the end of the pull")
    }

    // MARK: Cursor invalidation (§5)

    /// Condition 1: the epoch received differs from the cursor's. A reset or a restore on
    /// the Pi — a normal life-cycle event, never an error.
    func testAChangedEpochInvalidatesTheCursorAndRestartsAtTheBeginning() async {
        let api = FakeAPI(epoch: "epoch-2", events: history(1...10))
        let cursors = MemoryCursors()
        cursors.stored["raspcorse"] = EventCursor(epoch: "epoch-1", id: 7)
        let reader = HomeportEventsReader(api: api, cursors: cursors)

        guard let window = window(await reader.read(machine, mode: .sinceCursor,
                                                    advancingCursor: true)) else { return }
        XCTAssertTrue(window.cursorWasReset)
        XCTAssertTrue(window.isFullWindow, "a reset window replaces what was shown, never appends")
        XCTAssertEqual(window.events.map(\.id), Array(1...10),
                       "the whole new generation, from its beginning")
        XCTAssertEqual(cursors.stored["raspcorse"], EventCursor(epoch: "epoch-2", id: 10))
        XCTAssertEqual(api.requests.first?.sinceID, 7, "the first attempt still used the cursor")
        XCTAssertEqual(api.requests.first?.sinceEpoch, "epoch-1",
                       "§6: sending it gives the server an earlier chance to notice")
        XCTAssertEqual(api.requests.last?.sinceID, 0)
    }

    /// Condition 2: `latest_id` below the cursor. The epoch is unchanged — this is the
    /// restore path the contract says the server cannot see (§5), and the only protection
    /// the client really has.
    func testALatestIDBelowTheCursorInvalidatesItEvenWithAnUnchangedEpoch() async {
        let api = FakeAPI(epoch: "epoch-1", events: history(1...200))
        api.announcedLatestID = 200
        let cursors = MemoryCursors()
        cursors.stored["raspcorse"] = EventCursor(epoch: "epoch-1", id: 1481)
        let reader = HomeportEventsReader(api: api, cursors: cursors)

        guard let window = window(await reader.read(machine, mode: .sinceCursor, limit: 500,
                                                    advancingCursor: true)) else { return }
        XCTAssertTrue(window.cursorWasReset, "a shorter history is a substituted one")
        XCTAssertEqual(window.events.map(\.id), Array(1...200))
        XCTAssertEqual(cursors.stored["raspcorse"], EventCursor(epoch: "epoch-1", id: 200))
        XCTAssertEqual(api.requests.map(\.sinceID), [1481, 0])
    }

    /// And the invalidation is never raised as an error: §5 says a client does not report
    /// a generation change as a failure.
    func testAnInvalidCursorNeverProducesAFailureState() async {
        let api = FakeAPI(epoch: "epoch-2", events: history(1...3))
        let cursors = MemoryCursors()
        cursors.stored["raspcorse"] = EventCursor(epoch: "epoch-1", id: 99)
        let read = await HomeportEventsReader(api: api, cursors: cursors)
            .read(machine, mode: .sinceCursor)
        if case .window = read { return }
        XCTFail("a reset is a window, not \(read)")
    }

    func testAValidCursorReadsOnlyWhatCameAfterIt() async {
        let api = FakeAPI(epoch: "epoch-1", events: history(1...10))
        let cursors = MemoryCursors()
        cursors.stored["raspcorse"] = EventCursor(epoch: "epoch-1", id: 7)
        let reader = HomeportEventsReader(api: api, cursors: cursors)

        guard let window = window(await reader.read(machine, mode: .sinceCursor,
                                                    advancingCursor: true)) else { return }
        XCTAssertEqual(window.events.map(\.id), [8, 9, 10])
        XCTAssertFalse(window.cursorWasReset)
        XCTAssertFalse(window.isFullWindow, "an increment is appended, not substituted")
        XCTAssertEqual(cursors.stored["raspcorse"], EventCursor(epoch: "epoch-1", id: 10))
    }

    /// Nothing new: the cursor holds its place rather than falling back to the start of
    /// the epoch, which would make the next poll re-deliver the whole history.
    func testAnIncrementalReadWithNothingNewKeepsTheCursorWhereItIs() async {
        let api = FakeAPI(epoch: "epoch-1", events: history(1...10))
        let cursors = MemoryCursors()
        cursors.stored["raspcorse"] = EventCursor(epoch: "epoch-1", id: 10)
        let reader = HomeportEventsReader(api: api, cursors: cursors)

        guard let window = window(await reader.read(machine, mode: .sinceCursor,
                                                    advancingCursor: true)) else { return }
        XCTAssertTrue(window.events.isEmpty)
        XCTAssertEqual(cursors.stored["raspcorse"], EventCursor(epoch: "epoch-1", id: 10))
    }

    /// The history is substituted *while* the whole epoch is being paged through. What was
    /// collected belongs to a generation that no longer exists, so the pass starts over —
    /// once — rather than handing the tab an empty window on a machine full of events.
    func testAGenerationChangeMidPaginationRestartsTheReadRatherThanEmptyingIt() async {
        let api = FakeAPI(epoch: "epoch-1", events: history(1...400))
        // The second request is where the substitution lands: from then on the fake serves
        // epoch-2, and the events already collected under epoch-1 have to be dropped.
        let flipping = FlippingAPI(inner: api, flipOnRequest: 2, to: "epoch-2")
        let reader = HomeportEventsReader(api: flipping)

        guard let window = window(await reader.read(machine, mode: .window, limit: 200)) else { return }
        XCTAssertEqual(window.epoch, "epoch-2")
        XCTAssertTrue(window.cursorWasReset)
        XCTAssertTrue(window.isFullWindow)
        XCTAssertEqual(window.events.map(\.id), Array(201...400),
                       "the whole new generation was re-read, not left half-collected or empty")
    }

    /// Serves `inner`, but announces a different epoch from the nth request on — the only
    /// way to stage a substitution that lands between two pages of one pass.
    private final class FlippingAPI: HomeportEventsReading, @unchecked Sendable {
        let inner: FakeAPI
        let flipOnRequest: Int
        let to: String
        private var seen = 0

        init(inner: FakeAPI, flipOnRequest: Int, to: String) {
            self.inner = inner
            self.flipOnRequest = flipOnRequest
            self.to = to
        }

        func capabilities(of machine: Machine) async -> APIAvailability {
            await inner.capabilities(of: machine)
        }

        func events(of machine: Machine, sinceID: Int64, sinceEpoch: String?,
                    limit: Int) async -> EventsPageOutcome {
            seen += 1
            if seen == flipOnRequest { inner.epoch = to }
            return await inner.events(of: machine, sinceID: sinceID, sinceEpoch: sinceEpoch, limit: limit)
        }
    }

    /// Two invalidations in a row: the stored cursor is already stale against the served
    /// history, and the reader's one retry (after that first `.stale`) lands mid-pagination
    /// on a *second* epoch change. §5's remedy — one restart at the beginning — has already
    /// been spent, so the read must not loop hunting for a third generation: it reports the
    /// reset with an empty window, and the cursor moves to the epoch actually met.
    func testAStaleEpochTwiceInARowReportsAResetWithoutLooping() async {
        let api = FakeAPI(epoch: "epoch-2", events: history(1...400))
        // First request: the fake already answers "epoch-2", which does not match the
        // cursor's "epoch-1" — stale immediately. Third request (mid the retry's own
        // pagination): the epoch flips again, to "epoch-3" — stale a second time.
        let flipping = FlippingAPI(inner: api, flipOnRequest: 3, to: "epoch-3")
        let cursors = MemoryCursors()
        cursors.stored["raspcorse"] = EventCursor(epoch: "epoch-1", id: 100)
        let reader = HomeportEventsReader(api: flipping, cursors: cursors)

        guard let window = window(await reader.read(machine, mode: .sinceCursor, limit: 200,
                                                    advancingCursor: true)) else { return }
        XCTAssertTrue(window.events.isEmpty, "nothing stable was read across two invalidations")
        XCTAssertTrue(window.cursorWasReset)
        XCTAssertTrue(window.isFullWindow)
        XCTAssertEqual(window.epoch, "epoch-3", "the epoch actually met on the second attempt")
        XCTAssertEqual(cursors.stored["raspcorse"], EventCursor(epoch: "epoch-3", id: 0),
                       "the cursor still moves, to the start of whatever epoch answered last")
    }

    // MARK: Who may move the cursor

    /// AD-13 holds only because a window read is never gated by the cursor: `hpm events`
    /// and a freshly opened tab ask the same question and get the same answer, whatever
    /// the cursor happens to say.
    func testAWindowReadIgnoresWhereTheCursorSits() async {
        let api = FakeAPI(epoch: "epoch-1", events: history(1...10))
        let cursors = MemoryCursors()
        cursors.stored["raspcorse"] = EventCursor(epoch: "epoch-1", id: 9)
        let reader = HomeportEventsReader(api: api, cursors: cursors)

        guard let window = window(await reader.read(machine, mode: .window)) else { return }
        XCTAssertEqual(window.events.map(\.id), Array(1...10),
                       "the CLI must not show one event because the app read the other nine")
        XCTAssertEqual(api.requests.first?.sinceID, 0)
    }

    /// A CLI listing does not mark a journal read. Were it to move the cursor, the app's
    /// next incremental poll would skip exactly the events the CLI printed.
    func testAReadThatDoesNotAdvanceTheCursorLeavesItUntouched() async {
        let api = FakeAPI(epoch: "epoch-1", events: history(1...10))
        let cursors = MemoryCursors()
        cursors.stored["raspcorse"] = EventCursor(epoch: "epoch-1", id: 4)

        _ = await HomeportEventsReader(api: api, cursors: cursors)
            .read(machine, mode: .window, advancingCursor: false)
        XCTAssertEqual(cursors.stored["raspcorse"], EventCursor(epoch: "epoch-1", id: 4))
        XCTAssertEqual(cursors.writes, 0)
    }

    /// A window read still has to *report* a generation change: the caller was showing a
    /// history that no longer exists, even though the pull started at zero either way.
    func testAWindowReadStillReportsAGenerationChange() async {
        let api = FakeAPI(epoch: "epoch-2", events: history(1...3))
        let cursors = MemoryCursors()
        cursors.stored["raspcorse"] = EventCursor(epoch: "epoch-1", id: 2)

        guard let window = window(await HomeportEventsReader(api: api, cursors: cursors)
            .read(machine, mode: .window)) else { return }
        XCTAssertTrue(window.cursorWasReset)
    }

    /// hpm.db may be missing or unopenable; that degrades the reset detection, never the read.
    func testAReadWithoutACursorStoreStillWorks() async {
        let api = FakeAPI(events: history(1...5))
        guard let window = window(await HomeportEventsReader(api: api, cursors: nil)
            .read(machine, mode: .sinceCursor, advancingCursor: true)) else { return }
        XCTAssertEqual(window.events.map(\.id), Array(1...5))
        XCTAssertFalse(window.cursorWasReset)
    }

    // MARK: The three states (§8) reach the reader intact

    func testAnInstanceWithoutTheEventsFeatureIsUnavailableOnThisSurfaceOnly() async {
        let api = FakeAPI(events: history(1...5))
        api.features = ["metrics"]
        let read = await HomeportEventsReader(api: api).read(machine)
        XCTAssertEqual(read, .unavailable(.surfaceNotServed("events")))
        XCTAssertTrue(api.requests.isEmpty,
                      "§4: a client reads `features`, it never probes the endpoint to find out")
    }

    func testAHandshakeThatDoesNotHappenIsUnavailable() async {
        let api = FakeAPI()
        api.handshake = .unavailable(.notServed)
        let read = await HomeportEventsReader(api: api).read(machine)
        XCTAssertEqual(read, .unavailable(.notServed))
    }

    func testAnUnreachableHandshakeIsUnreachable() async {
        let api = FakeAPI()
        api.handshake = .unreachable("HTTP 503")
        let read = await HomeportEventsReader(api: api).read(machine)
        XCTAssertEqual(read, .unreachable("HTTP 503"))
    }

    func testAnUnreachablePageStaysUnreachableAndInvalidatesNothing() async {
        let api = FakeAPI(events: history(1...5))
        api.pageOutcome = .unreachable("HTTP 500")
        let cursors = MemoryCursors()
        cursors.stored["raspcorse"] = EventCursor(epoch: "epoch-1", id: 3)

        let read = await HomeportEventsReader(api: api, cursors: cursors)
            .read(machine, mode: .sinceCursor, advancingCursor: true)
        XCTAssertEqual(read, .unreachable("HTTP 500"))
        XCTAssertEqual(cursors.stored["raspcorse"], EventCursor(epoch: "epoch-1", id: 3),
                       "§8: a server failure invalidates nothing")
    }

    func testAContractOutOfRangeReachesTheReaderAsUnavailable() async {
        let api = FakeAPI(events: history(1...5))
        api.contract = "2.0.0"
        let read = await HomeportEventsReader(api: api).read(machine)
        XCTAssertEqual(read, .unavailable(.incompatibleContract(.tooNew(SemanticVersion(2, 0, 0)))))
    }

    // MARK: Cancellation is never a network failure

    /// A cancelled handshake (the caller's own task went away, e.g. a tab switch) must
    /// reach the reader as its own state — never folded into `.unreachable`, which would
    /// have `EventFeed` persist a false "injoignable" over a feed that survives the task.
    func testACancelledHandshakeReachesTheReaderAsCancelledNotUnreachable() async {
        let api = FakeAPI()
        api.handshake = .cancelled
        let read = await HomeportEventsReader(api: api).read(machine)
        XCTAssertEqual(read, .cancelled)
    }

    func testACancelledPageFetchReachesTheReaderAsCancelledAndInvalidatesNothing() async {
        let api = FakeAPI(events: history(1...5))
        api.pageOutcome = .cancelled
        let cursors = MemoryCursors()
        cursors.stored["raspcorse"] = EventCursor(epoch: "epoch-1", id: 3)

        let read = await HomeportEventsReader(api: api, cursors: cursors)
            .read(machine, mode: .sinceCursor, advancingCursor: true)
        XCTAssertEqual(read, .cancelled)
        XCTAssertEqual(cursors.stored["raspcorse"], EventCursor(epoch: "epoch-1", id: 3),
                       "a cancellation invalidates nothing, same as a server failure")
    }

    // MARK: The shared filter (AD-13)

    func testTheSeverityFilterIsTheSameOneBothSurfacesApply() async {
        let events = history(1...3) + [
            HomeportEvent(id: 4, timestamp: Date(timeIntervalSince1970: 4), kind: "service.down",
                          severity: .critical, subject: "homeassistant", detail: nil),
            HomeportEvent(id: 5, timestamp: Date(timeIntervalSince1970: 5), kind: "temp.high",
                          severity: .warning, subject: "cpu", detail: "71 °C"),
        ]
        XCTAssertEqual(events.filtered(severity: nil).map(\.id), [1, 2, 3, 4, 5],
                       "no severity means all — the CLI's absent option and the picker's first segment")
        XCTAssertEqual(events.filtered(severity: .critical).map(\.id), [4])
        XCTAssertEqual(events.filtered(severity: .warning).map(\.id), [5])
        XCTAssertEqual(events.filtered(severity: .info).map(\.id), [1, 2, 3])
    }

    // MARK: The cursor round-trips through hpm.db

    func testTheCursorSurvivesTheStoreAndTheV1ToV2Migration() throws {
        let root = NSTemporaryDirectory() + "hpm-events-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let path = root + "/state/hpm/hpm.db"

        let store = try HistoryStore(path: path)
        XCTAssertNil(try store.eventCursor(machine: "raspcorse"), "never read yet is nil, not zero")
        try store.setEventCursor(EventCursor(epoch: "epoch-1", id: 1481), machine: "raspcorse")
        XCTAssertEqual(try store.eventCursor(machine: "raspcorse"),
                       EventCursor(epoch: "epoch-1", id: 1481))

        // A new generation replaces the row outright — a cursor is never merged with the
        // one it invalidates.
        try store.setEventCursor(EventCursor(epoch: "epoch-2", id: 3), machine: "raspcorse")
        XCTAssertEqual(try store.eventCursor(machine: "raspcorse"), EventCursor(epoch: "epoch-2", id: 3))
        XCTAssertNil(try store.eventCursor(machine: "raspyellow"), "cursors are per machine")

        try store.clearEventCursor(machine: "raspcorse")
        XCTAssertNil(try store.eventCursor(machine: "raspcorse"))
        XCTAssertNoThrow(try store.clearEventCursor(machine: "raspcorse"), "clearing twice is idempotent")

        // And it survives a reopen — the migration must not run twice and wipe it.
        try store.setEventCursor(EventCursor(epoch: "epoch-2", id: 9), machine: "raspcorse")
        XCTAssertEqual(try HistoryStore(path: path).eventCursor(machine: "raspcorse"),
                       EventCursor(epoch: "epoch-2", id: 9))
    }
}
