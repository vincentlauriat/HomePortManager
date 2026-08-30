import XCTest
@testable import HomePortKit

/// The reader both the Metrics tab and `hpm metrics` go through — the handshake, the
/// `features` guard of §4, the three states of §8 — and the pure functions the two surfaces
/// draw and print from.
final class ManagerMetricsTests: XCTestCase {
    private let machine = Machine(name: "raspcorse", ssh: "raspcorse", port: 80)

    // MARK: Doubles

    /// An instance that answers like §4 and §7 say a server must. Records the ranges it was
    /// asked for, so "the guard came before the call" can be asserted rather than assumed.
    private final class FakeAPI: HomeportMetricsReading, @unchecked Sendable {
        var features: [String] = ["events", "metrics"]
        var contract = "1.0.0"
        var epoch = "epoch-1"
        var handshake: APIAvailability?
        var outcome: MetricsOutcome?
        private(set) var asked: [MetricsRange] = []

        func capabilities(of machine: Machine) async -> APIAvailability {
            if let handshake { return handshake }
            let compatibility = HomeportAPIContract.compatibility(with: contract)
            guard case .compatible(let version) = compatibility else {
                return .unavailable(.incompatibleContract(compatibility))
            }
            return .available(HomeportCapabilities(contract: version, server: "0.8.0",
                                                   epoch: epoch, features: features))
        }

        func metrics(of machine: Machine, range: MetricsRange) async -> MetricsOutcome {
            asked.append(range)
            return outcome ?? .window(ManagerMetricsTests.window(range: range))
        }
    }

    private static func series(_ kind: MetricKind, _ points: [Double?]) -> MetricSeries {
        MetricSeries(kind: kind, points: points)
    }

    static func window(range: MetricsRange = .h24, stepS: Int = 60,
                       cpu: [Double?] = [1, 2, 3, 4],
                       temp: [Double?] = [10, 11, 12, 13]) -> MetricsWindow {
        MetricsWindow(epoch: "epoch-1", range: range, stepS: stepS,
                      from: Date(timeIntervalSince1970: 1000),
                      to: Date(timeIntervalSince1970: 1000 + Double(stepS * cpu.count)),
                      cpu: series(.cpu, cpu),
                      memory: series(.memory, [40, 41, 42, 43]),
                      disk: series(.disk, [67, 67, 67, 67]),
                      temperature: series(.temperature, temp))
    }

    // MARK: The handshake and its guard (§4)

    func testAServedInstanceReturnsTheWindowForTheRangeAskedFor() async {
        let api = FakeAPI()
        guard case .window(let window) = await HomeportMetricsReader(api: api).read(machine, range: .d7) else {
            return XCTFail("a served instance answers with a window")
        }
        XCTAssertEqual(window.range, .d7)
        XCTAssertEqual(api.asked, [.d7], "the range asked for is the one passed through")
    }

    func testTheDefaultRangeIsTheContractsOwn() async {
        let api = FakeAPI()
        _ = await HomeportMetricsReader(api: api).read(machine)
        XCTAssertEqual(api.asked, [.h24], "§7's own default")
    }

    /// §4: `features` is the source of truth, and a client does not probe an endpoint to
    /// find out whether it exists. An instance that serves events and not metrics must never
    /// see a `metrics` request at all.
    func testAnInstanceThatDoesNotAnnounceMetricsIsNeverAsked() async {
        let api = FakeAPI()
        api.features = ["events"]
        let outcome = await HomeportMetricsReader(api: api).read(machine, range: .h24)
        XCTAssertEqual(outcome, .unavailable(.surfaceNotServed("metrics")))
        XCTAssertTrue(api.asked.isEmpty, "the guard comes before the call (§4)")
    }

    func testAnInstanceWithNoAPIIsUnavailableNotBroken() async {
        let api = FakeAPI()
        api.handshake = .unavailable(.notServed)
        let outcome = await HomeportMetricsReader(api: api).read(machine)
        XCTAssertEqual(outcome, .unavailable(.notServed))
        XCTAssertTrue(api.asked.isEmpty)
    }

    func testAContractOutsideTheRangeNamesTheVersionMet() async {
        let api = FakeAPI()
        api.contract = "2.0.0"
        guard case .unavailable(.incompatibleContract(let compatibility)) =
                await HomeportMetricsReader(api: api).read(machine) else {
            return XCTFail("an out-of-range contract is unavailable, and names its version")
        }
        XCTAssertEqual(compatibility.describedVersion, "2.0.0")
    }

    func testAnUnreachableMachineStaysUnreachableThroughTheReader() async {
        let api = FakeAPI()
        api.handshake = .unreachable("The request timed out (NSURLErrorDomain -1001)")
        guard case .unreachable(let detail) = await HomeportMetricsReader(api: api).read(machine) else {
            return XCTFail("an unreachable machine is not an unavailable surface")
        }
        XCTAssertTrue(detail.contains("-1001"))
        XCTAssertTrue(api.asked.isEmpty)
    }

    /// A cancellation is the caller's own task going away, and it must reach the feed as
    /// itself: applied as `unreachable` it would leave a false "injoignable" over curves the
    /// cancelling task never invalidated.
    func testACancelledHandshakeIsReportedAsCancelled() async {
        let api = FakeAPI()
        api.handshake = .cancelled
        let outcome = await HomeportMetricsReader(api: api).read(machine)
        XCTAssertEqual(outcome, .cancelled)
    }

    func testAFailureOfTheMetricsCallItselfIsPassedThroughUntouched() async {
        for outcome in [MetricsOutcome.unavailable(.surfaceNotServed("metrics")),
                        .unreachable("HTTP 503"), .cancelled] {
            let api = FakeAPI()
            api.outcome = outcome
            let read = await HomeportMetricsReader(api: api).read(machine)
            XCTAssertEqual(read, outcome,
                           "the reader classifies nothing the client already classified")
        }
    }

    // MARK: The pure functions both surfaces read from

    /// §7: a null is an absence, so the most recent *measurement* is the last non-null —
    /// not the last slot, which would read as a machine at zero.
    func testTheCurrentValueIsTheLastMeasurementNotTheLastSlot() {
        XCTAssertEqual(Self.series(.cpu, [1.0, nil, nil, 2.0]).current, 2.0)
        XCTAssertEqual(Self.series(.cpu, [1.0, 2.0, nil]).current, 2.0,
                       "a window that ends on a hole still has a last measurement")
        XCTAssertNil(Self.series(.cpu, [nil, nil]).current,
                     "§9 forbids assuming a series contains a measurement")
    }

    func testTheExtremesIgnoreTheHoles() {
        let series = Self.series(.temperature, [48.5, nil, 52.0, nil, 47.9])
        XCTAssertEqual(series.minimum, 47.9)
        XCTAssertEqual(series.maximum, 52.0)
        XCTAssertNil(Self.series(.temperature, [nil, nil]).minimum)
        XCTAssertNil(Self.series(.temperature, [nil, nil]).maximum)
    }

    /// The matrix's own case: `[1.0, null, null, 2.0]` is two runs of one point, and the
    /// curve must not join them. Each run keeps its grid index, which is what turns back
    /// into an instant.
    func testAHoleSplitsTheSeriesIntoRunsThatKeepTheirGridIndex() {
        let series = Self.series(.cpu, [1.0, nil, nil, 2.0])
        XCTAssertEqual(series.segments, [[MetricPoint(index: 0, value: 1.0)],
                                         [MetricPoint(index: 3, value: 2.0)]])
        XCTAssertEqual(series.current, 2.0)
    }

    func testAContiguousSeriesIsOneRunAndAnEmptyOneIsNone() {
        XCTAssertEqual(Self.series(.cpu, [1.0, 2.0, 3.0]).segments,
                       [[MetricPoint(index: 0, value: 1.0),
                         MetricPoint(index: 1, value: 2.0),
                         MetricPoint(index: 2, value: 3.0)]])
        XCTAssertEqual(Self.series(.cpu, []).segments, [])
        XCTAssertEqual(Self.series(.temperature, Array(repeating: nil, count: 1440)).segments, [],
                       "a machine with no thermal sensor draws nothing, and is still a card")
    }

    func testARunThatEndsTheWindowIsNotDropped() {
        XCTAssertEqual(Self.series(.cpu, [nil, 5.0]).segments,
                       [[MetricPoint(index: 1, value: 5.0)]],
                       "the last run is closed when the points run out, not only by a hole")
    }

    /// §7: `from + i * step_s`, with the step as served — the client never resamples, and no
    /// range-to-step table exists to fall back on.
    func testAnInstantIsTheServedGridAndNothingElse() {
        let window = Self.window(range: .d30, stepS: 3600)
        XCTAssertEqual(window.timestamp(at: 0), window.from)
        XCTAssertEqual(window.timestamp(at: 3), Date(timeIntervalSince1970: 1000 + 3 * 3600))
        XCTAssertEqual(window.pointCount, 4)
        XCTAssertEqual(window.series.map(\.kind), [.cpu, .memory, .disk, .temperature])
    }

    /// One writer for both surfaces: the card's current value and the CLI cell must read the
    /// same digits for the same point (FR11/AD-13), and each names its own absent marker.
    func testAMeasurementIsWrittenTheSameWayForBothSurfaces() {
        XCTAssertEqual(MetricValue.text(12.44), "12.4")
        XCTAssertEqual(MetricValue.text(0), "0.0")
        XCTAssertEqual(MetricValue.text(nil), "—")
        XCTAssertEqual(MetricValue.text(nil, absent: "-"), "-")
    }

    /// §7 pins 0–100 for the three percentages and leaves temperature open; a view must not
    /// have to know which is which a second time.
    func testTheContractsUnitsAndScalesLiveOnTheSeriesKind() {
        XCTAssertEqual(MetricKind.cpu.unit, "%")
        XCTAssertEqual(MetricKind.temperature.unit, "°C")
        XCTAssertEqual(MetricKind.disk.scale, 0...100)
        XCTAssertNil(MetricKind.temperature.scale)
        XCTAssertEqual(MetricKind.allCases.map(\.rawValue),
                       ["cpu_pct", "mem_pct", "disk_pct", "temp_c"],
                       "the wire names of §7, and no fifth case a later minor could land in")
    }

    func testTheFourRangesAreTheContractsOwnWireValues() {
        XCTAssertEqual(MetricsRange.allCases.map(\.rawValue), ["24h", "7d", "30d", "1y"])
    }

    /// The render probe showed four full-length dates ("28 août à 16 h") running into one
    /// another on the ~260 pt plot a card gets at the window's 900 pt minimum. Each range
    /// writes only the component that varies across it. Pinned under a fixed locale and
    /// time zone: what is asserted is the choice of components, not the user's formatting.
    func testATimeAxisLabelIsShortEnoughToReadOnACard() {
        let instant = Date(timeIntervalSince1970: 1_787_990_400)  // 2026-08-29T08:00:00Z
        func label(_ range: MetricsRange) -> String {
            var style = range.axisDateFormat
            style.locale = Locale(identifier: "en_US_POSIX")
            style.timeZone = TimeZone(identifier: "UTC")!
            // Foundation separates the two parts with a narrow no-break space (U+202F);
            // normalised so the expectation below stays readable.
            return instant.formatted(style)
                .replacingOccurrences(of: "\u{202F}", with: " ")
                .replacingOccurrences(of: "\u{00A0}", with: " ")
        }
        XCTAssertEqual(label(.h24), "8 AM", "inside a day, only the hour varies")
        XCTAssertEqual(label(.d7), "Sat", "inside a week, only the weekday")
        XCTAssertEqual(label(.d30), "Aug 29", "inside a month, the day")
        XCTAssertEqual(label(.y1), "Aug", "inside a year, the month")
        for range in MetricsRange.allCases {
            XCTAssertLessThanOrEqual(label(range).count, 8,
                                     "\(range.rawValue): a label this long is what overlapped")
        }
    }

    func testTheTimeAxisCarriesAtMostFourMarks() {
        XCTAssertEqual(MetricsRange.axisMarkCount, 4)
    }

    // MARK: - Generation change (§5, §7)

    /// The very first read of a machine has nothing to differ from: announcing a new
    /// generation there would announce the machine's own history to itself.
    func testAFirstReadNeverAnnouncesANewGeneration() {
        XCTAssertFalse(Self.window().startsANewGeneration(after: nil))
    }

    func testTheSameEpochTwiceIsTheSameHistory() {
        XCTAssertFalse(Self.window().startsANewGeneration(after: "epoch-1"))
    }

    /// §5: opaque, compared by equality and nothing else — no order, no format, no prefix.
    func testAnEpochThatMovedReplacesTheCurves() {
        XCTAssertTrue(Self.window().startsANewGeneration(after: "epoch-0"),
                      "the curves on screen belong to a history that no longer exists")
        XCTAssertTrue(Self.window().startsANewGeneration(after: ""),
                      "an empty epoch is a value like any other, not an absence")
    }
}
