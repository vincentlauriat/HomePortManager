import Foundation

/// The client half of the Homeport v1 contract (`docs/api/homeport-api-v1.md`): the
/// `capabilities` handshake and the `events` pull, decoded exactly as §4 and §6 describe
/// and classified exactly as §8 prescribes.
///
/// Two rules shape every signature here. First, **no failure of the contract is an error**:
/// a server that does not serve the API, one whose version is out of range, one that does
/// not answer — all three are values the interface renders, never exceptions a caller has
/// to catch (§8). Second, the client **never extends the contract** (AD-4): an unknown
/// severity is folded, an unknown `kind` is carried through untouched, an unknown feature
/// is ignored.
///
/// This is the first `URLSession` in the repo — every other remote call goes through
/// `curl` under `ProcessRunner`. AD-3 mandates it, over the single App Transport Security
/// exception the app already declares for the dashboard's `WKWebView`; no second bypass
/// exists anywhere.

// MARK: - What the contract serves

/// The `capabilities` handshake (§4), already validated: a value of this type means the
/// handshake happened *and* the announced contract sits inside the range hpm consumes.
public struct HomeportCapabilities: Equatable, Sendable {
    /// Parsed and in range — an out-of-range version never reaches this type.
    public let contract: SemanticVersion
    /// Homeport's own version, informational only. §9: it decides nothing.
    public let server: String?
    /// Opaque (§5): compared by equality, never interpreted.
    public let epoch: String
    /// The surfaces this instance actually serves. §4: the one source of truth on
    /// availability — a client reads it rather than probing an endpoint.
    public let features: [String]

    public init(contract: SemanticVersion, server: String?, epoch: String, features: [String]) {
        self.contract = contract
        self.server = server
        self.epoch = epoch
        self.features = features
    }

    public func serves(_ feature: String) -> Bool { features.contains(feature) }
}

/// The severity of one event (§6). Three values in v1; a fourth added by a later minor
/// folds to `warning` — visible without notifying, which is what keeps "only `critical`
/// notifies" true without exception.
public enum EventSeverity: String, Equatable, Sendable, CaseIterable {
    case info, warning, critical

    /// The contract's conduct in one place: never reject, never hide.
    public init(apiValue raw: String) {
        self = EventSeverity(rawValue: raw) ?? .warning
    }

    /// The severity a `StatusPill` renders. The app has exactly one pill, typed on
    /// `FleetRow.Severity`; mapping here rather than growing a second pill component is
    /// what keeps colour and label decided in a single place.
    public var displaySeverity: FleetRow.Severity {
        switch self {
        case .info: return .ok
        case .warning: return .warning
        case .critical: return .critical
        }
    }
}

/// One line of a machine's event journal (§6).
public struct HomeportEvent: Equatable, Sendable, Identifiable {
    /// Strictly increasing inside an epoch, **not** contiguous — a purge leaves holes (§9).
    public let id: Int64
    /// §6: not guaranteed to increase with `id`; a clock step back can date a newer event
    /// earlier. Reading order is the order of `id`, never of this.
    public let timestamp: Date
    /// Carried through as served: §6 forbids making the display depend on recognising it.
    public let kind: String
    public let severity: EventSeverity
    public let subject: String
    /// May be absent because it was never recorded or is masked — never because the
    /// information does not exist (§6).
    public let detail: String?

    public init(id: Int64, timestamp: Date, kind: String, severity: EventSeverity,
                subject: String, detail: String?) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.severity = severity
        self.subject = subject
        self.detail = detail
    }

    /// What precedes the first dot — the only decomposition of `kind` a client may lean
    /// on, and only for grouping (§6).
    public var family: String {
        kind.split(separator: ".", maxSplits: 1).first.map(String.init) ?? kind
    }
}

/// One `events` response (§6), as served: ascending by `id`.
public struct EventPage: Equatable, Sendable {
    public let epoch: String
    /// The greatest `id` in this epoch, independent of the filter and of `limit`; `0` when
    /// the history is empty. The client's real protection against a restored history (§5).
    public let latestID: Int64
    public let events: [HomeportEvent]
    public let hasMore: Bool

    public init(epoch: String, latestID: Int64, events: [HomeportEvent], hasMore: Bool) {
        self.epoch = epoch
        self.latestID = latestID
        self.events = events
        self.hasMore = hasMore
    }
}

// MARK: - What a client concludes from a failure (§8)

/// Why a surface is not there. Every case is a state to show, and every one of them points
/// the user at an update — never at a broken machine.
public enum APIUnavailableReason: Equatable, Sendable {
    /// `capabilities` answered 404, or answered 200 with a body that is not the handshake.
    /// §4 is explicit that the two are the same conclusion: a missing or mistyped
    /// `contract`, `epoch` or `features` is "the handshake did not happen", and a client
    /// never guesses a missing field.
    case notServed
    /// The announced version is outside `>= 1.0.0 < 2.0.0`. Carries the verdict so the
    /// interface can name the version it met (§8, row 2).
    case incompatibleContract(ContractCompatibility)
    /// The surface is absent from `features`, or announced there and answering 404 — §8
    /// folds the second case into the first on purpose: an announcement that does not match
    /// the service is never a breakdown.
    case surfaceNotServed(String)
}

/// The verdict of the `capabilities` handshake — the three states the interface renders.
public enum APIAvailability: Equatable, Sendable {
    case available(HomeportCapabilities)
    case unavailable(APIUnavailableReason)
    /// Network error, timeout or 5xx. Distinct from `unavailable` because the two are
    /// resolved at opposite ends: one by an update, the other by a hand on the machine.
    /// Carries the underlying description for the detail line.
    case unreachable(String)
    /// The fetch was cancelled — the caller's own task went away (a tab switch mid-fetch),
    /// not the machine. Kept apart from `unreachable` so a cancellation can never persist
    /// a false "injoignable" over a feed that survives the cancelling task.
    case cancelled
}

/// The verdict of one `events` call, in the same shapes.
public enum EventsPageOutcome: Equatable, Sendable {
    case page(EventPage)
    case unavailable(APIUnavailableReason)
    case unreachable(String)
    /// Same distinction as `APIAvailability.cancelled`, for the same reason.
    case cancelled
}

// MARK: - The metrics surface (§7)

/// A window a client may ask for (§7). These four values are the whole vocabulary, and the
/// contract answers an unknown one with a **400** rather than clamping it the way `events`
/// clamps `limit`: there is no neighbouring range to fall back on.
public enum MetricsRange: String, Equatable, Sendable, CaseIterable {
    case h24 = "24h"
    case d7 = "7d"
    case d30 = "30d"
    case y1 = "1y"

    /// A plain-string label, for the CLI and for anything that cannot reach a catalog. The
    /// app maps the cases to its own `metrics.range.*` keys instead: `HomePortKit` never
    /// imports SwiftUI, so a `LocalizedStringKey` cannot live here.
    public var label: String {
        switch self {
        case .h24: return "24 h"
        case .d7: return "7 d"
        case .d30: return "30 d"
        case .y1: return "1 y"
        }
    }

    /// How an instant is written on the time axis of a card, and how many marks that axis
    /// may carry.
    ///
    /// The automatic style writes a date at full length ("28 août à 16 h"). Four of those
    /// on the ~260 pt plot a card gets at the window's 900 pt minimum overlap into an
    /// unreadable run — seen in the render probe, on the real 24 h window of `raspcorse`.
    /// Each range therefore names the one component that actually varies across it: the
    /// hour inside a day, the weekday inside a week, the day inside a month, the month
    /// inside a year. Localised by the caller's locale like any other `FormatStyle`.
    public var axisDateFormat: Date.FormatStyle {
        switch self {
        case .h24: return .dateTime.hour()
        case .d7: return .dateTime.weekday(.abbreviated)
        case .d30: return .dateTime.day().month(.abbreviated)
        case .y1: return .dateTime.month(.abbreviated)
        }
    }

    /// Marks a card's time axis may carry. Four is what a 260 pt plot holds without the
    /// labels touching, once `axisDateFormat` has shortened them.
    public static let axisMarkCount = 4
}

/// The four series of the v1 contract, keyed by their wire names (§7).
///
/// Exhaustive and deliberately without an `unknown` case: §7 has a v1.0 client ignore a key
/// it does not know, and a catch-all would turn a series added by a later minor into a
/// fifth card this version can neither label nor scale.
public enum MetricKind: String, Equatable, Sendable, CaseIterable {
    case cpu = "cpu_pct"
    case memory = "mem_pct"
    case disk = "disk_pct"
    case temperature = "temp_c"

    /// Machine content, shown as served — never translated.
    public var unit: String {
        switch self {
        case .cpu, .memory, .disk: return "%"
        case .temperature: return "°C"
        }
    }

    /// The scale a chart pins when the contract fixes one: §7 gives the three percentages a
    /// 0–100 range and leaves temperature open. Answered here rather than in the view so
    /// every surface drawing these series answers it the same way.
    public var scale: ClosedRange<Double>? {
        switch self {
        case .cpu, .memory, .disk: return 0...100
        case .temperature: return nil
        }
    }
}

/// One measured point, carrying the grid index it sits at. The index is what turns back
/// into an instant through `MetricsWindow.timestamp(at:)` — the served grid and nothing
/// else (§7).
public struct MetricPoint: Equatable, Sendable, Identifiable {
    public let index: Int
    public let value: Double

    public init(index: Int, value: Double) {
        self.index = index
        self.value = value
    }

    public var id: Int { index }
}

/// One series of a window: the contract's own array, holes included.
public struct MetricSeries: Equatable, Sendable {
    public let kind: MetricKind
    /// One entry per grid slot. A `nil` is "no measurement" — never a zero, never
    /// interpolated (§7).
    public let points: [Double?]

    public init(kind: MetricKind, points: [Double?]) {
        self.kind = kind
        self.points = points
    }

    /// The most recent measurement, or nil when the series holds none at all — §9 forbids
    /// assuming a series contains one.
    public var current: Double? { points.last(where: { $0 != nil }) ?? nil }

    public var minimum: Double? { points.compactMap { $0 }.min() }
    public var maximum: Double? { points.compactMap { $0 }.max() }

    /// The contiguous runs of measured points. Splitting here rather than in the view is
    /// what keeps a curve from crossing a hole: Swift Charts joins two consecutive
    /// `LineMark`s whatever was omitted between them, so every run has to carry its own
    /// `series:` value. Decidable, therefore here and tested (§7: a `null` never
    /// interpolates — a curve stops there).
    public var segments: [[MetricPoint]] {
        var runs: [[MetricPoint]] = []
        var run: [MetricPoint] = []
        for (index, value) in points.enumerated() {
            if let value {
                run.append(MetricPoint(index: index, value: value))
            } else if !run.isEmpty {
                runs.append(run)
                run = []
            }
        }
        if !run.isEmpty { runs.append(run) }
        return runs
    }
}

/// How a measurement is written, in one place for both surfaces: the current value of a
/// card and the cell of `hpm metrics` must read identically for the same point (FR11,
/// AD-13). Unlocalised on purpose — these are machine-produced numbers, rendered like every
/// other piece of machine content.
public enum MetricValue {
    /// What an absent measurement looks like on screen. The CLI passes its own marker: its
    /// table is padded in ASCII columns, where an em dash reads as a rule.
    public static let absentMarker = "—"

    public static func text(_ value: Double?, absent: String = MetricValue.absentMarker) -> String {
        guard let value else { return absent }
        // Locale-free by construction (`String(format:)` with no locale), so the table, the
        // card and the tests all read the same digits.
        return String(format: "%.1f", value)
    }
}

/// One `metrics` response (§7), already validated: a value of this type means the served
/// grid is internally coherent and the four known series are present at its exact length.
public struct MetricsWindow: Equatable, Sendable {
    public let epoch: String
    /// The range **as served** — the grid below belongs to it.
    public let range: MetricsRange
    public let stepS: Int
    /// Included (§7).
    public let from: Date
    /// Excluded (§7).
    public let to: Date
    public let cpu: MetricSeries
    public let memory: MetricSeries
    public let disk: MetricSeries
    public let temperature: MetricSeries

    public init(epoch: String, range: MetricsRange, stepS: Int, from: Date, to: Date,
                cpu: MetricSeries, memory: MetricSeries, disk: MetricSeries,
                temperature: MetricSeries) {
        self.epoch = epoch
        self.range = range
        self.stepS = stepS
        self.from = from
        self.to = to
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
        self.temperature = temperature
    }

    /// The four series in the one order both surfaces show them in.
    public var series: [MetricSeries] { [cpu, memory, disk, temperature] }

    /// `(to - from) / step_s`, which the validation already proved every series matches.
    public var pointCount: Int { cpu.points.count }

    /// §7: the instant of point `i` is `from + i * step_s`, computed from the served grid
    /// and nothing else. No range-to-step table is hardcoded anywhere in this client.
    public func timestamp(at index: Int) -> Date {
        from.addingTimeInterval(TimeInterval(index) * TimeInterval(stepS))
    }
}

/// The verdict of one `metrics` call, in the same shapes as the rest of the contract.
public enum MetricsOutcome: Equatable, Sendable {
    case window(MetricsWindow)
    case unavailable(APIUnavailableReason)
    case unreachable(String)
    /// Same distinction as `APIAvailability.cancelled`, for the same reason.
    case cancelled
}

// MARK: - The seam

/// One HTTP exchange, reduced to what the contract needs. The status code is kept apart
/// from the body because §8 decides mostly on the code.
public struct HTTPReply: Equatable, Sendable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// The single point where this file touches the network — replaced wholesale in tests, so
/// the decoding and the §8 classification under test are the production ones.
public typealias HomeportHTTPFetch = @Sendable (URL) async throws -> HTTPReply

/// What `Manager+Events` reads through. A protocol rather than the concrete client so the
/// pull, the cursor and the pagination can be tested without a socket.
public protocol HomeportEventsReading: Sendable {
    func capabilities(of machine: Machine) async -> APIAvailability
    func events(of machine: Machine, sinceID: Int64, sinceEpoch: String?,
                limit: Int) async -> EventsPageOutcome
}


/// What `Manager+Metrics` reads through. Kept alongside `HomeportEventsReading` rather than
/// merged into it: §4 lets an instance serve one surface and not the other, and a single
/// protocol would make every fake for one carry the other.
public protocol HomeportMetricsReading: Sendable {
    func capabilities(of machine: Machine) async -> APIAvailability
    func metrics(of machine: Machine, range: MetricsRange) async -> MetricsOutcome
}

// MARK: - The client

public struct HomeportAPIClient: HomeportEventsReading, HomeportMetricsReading {
    /// The `events` surface name, as it appears in `features` (§4).
    public static let eventsFeature = "events"
    /// The `metrics` surface name, likewise (§4).
    public static let metricsFeature = "metrics"

    private let fetch: HomeportHTTPFetch

    public init(fetch: @escaping HomeportHTTPFetch = HomeportAPIClient.urlSessionFetch()) {
        self.fetch = fetch
    }

    /// The default transport. Ephemeral and cache-defeating: an event feed that answered
    /// from a URL cache would show a machine's past as its present. The timeout is what
    /// turns a silent tailnet into the `unreachable` state instead of a hung tab.
    public static func urlSessionFetch(timeout: TimeInterval = 10) -> HomeportHTTPFetch {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 3
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: configuration)
        return { url in
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                // Nothing but HTTP can reach this URL, but a non-HTTP response would
                // otherwise be read as a status of 0 and classified as unreachable by
                // accident rather than by decision.
                throw HPMError("non-HTTP response from \(url.absoluteString)")
            }
            return HTTPReply(status: http.statusCode, body: data)
        }
    }

    /// The v1 address of a surface on a machine. Built on `dashboardURL(for:)` so the host
    /// derivation and its allowlist are the ones story 1.4 already vetted (AD-3); only the
    /// path and the query differ.
    public static func endpoint(_ path: String, on machine: Machine,
                                query: [URLQueryItem] = []) -> URL? {
        guard let base = dashboardURL(for: machine),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { return nil }
        components.path = "/api/v1/\(path)"
        components.queryItems = query.isEmpty ? nil : query
        return components.url
    }

    // MARK: capabilities (§4)

    public func capabilities(of machine: Machine) async -> APIAvailability {
        guard let url = Self.endpoint("capabilities", on: machine) else {
            // No address can be derived from this machine's fleet.yaml identity. That is
            // neither "Homeport is too old" — which would send the user to Updates, the
            // wrong place — nor a healthy machine: it cannot be reached, and the detail
            // says why.
            return .unreachable("no API address can be derived from the ssh target of \(machine.name)")
        }
        let reply: HTTPReply
        do {
            reply = try await fetch(url)
        } catch {
            if Self.isCancellation(error) { return .cancelled }
            return .unreachable(describe(error))
        }
        switch reply.status {
        case 200:
            break
        case 404:
            return .unavailable(.notServed)
        default:
            // 5xx is "retry later, invalidate nothing" (§8); any other unexpected code
            // gets the same treatment rather than a conclusion the contract does not draw.
            return .unreachable("HTTP \(reply.status)")
        }
        guard let payload = try? JSONDecoder().decode(CapabilitiesPayload.self, from: reply.body) else {
            // §4: a handshake missing a field, or carrying one of the wrong type, is
            // treated *exactly* like a 404.
            return .unavailable(.notServed)
        }
        let compatibility = HomeportAPIContract.compatibility(with: payload.contract)
        guard case .compatible(let version) = compatibility else {
            return .unavailable(.incompatibleContract(compatibility))
        }
        return .available(HomeportCapabilities(contract: version,
                                               server: payload.server,
                                               epoch: payload.epoch,
                                               features: payload.features))
    }

    // MARK: events (§6)

    public func events(of machine: Machine, sinceID: Int64, sinceEpoch: String?,
                       limit: Int) async -> EventsPageOutcome {
        // Clamped here rather than left to the server. §6 says a server brings an
        // out-of-bounds value back into range, but a client that relies on that is a
        // client that would send `limit=0` to a stricter implementation and read the
        // rejection as a broken machine.
        var query = [
            URLQueryItem(name: "since_id", value: String(max(sinceID, 0))),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 1000))),
        ]
        // §6: optional, and worth sending — it gives the server a second, earlier chance
        // to notice the cursor belongs to another generation.
        if let sinceEpoch, !sinceEpoch.isEmpty {
            query.append(URLQueryItem(name: "since_epoch", value: sinceEpoch))
        }
        guard let url = Self.endpoint("events", on: machine, query: query) else {
            return .unreachable("no API address can be derived from the ssh target of \(machine.name)")
        }
        let reply: HTTPReply
        do {
            reply = try await fetch(url)
        } catch {
            if Self.isCancellation(error) { return .cancelled }
            return .unreachable(describe(error))
        }
        switch reply.status {
        case 200:
            break
        case 404:
            // §8: a surface announced in `features` that answers 404 is treated exactly
            // like one absent from `features` — never as a breakdown.
            return .unavailable(.surfaceNotServed(Self.eventsFeature))
        default:
            return .unreachable("HTTP \(reply.status)")
        }
        guard let payload = try? JSONDecoder().decode(EventsPayload.self, from: reply.body) else {
            // A body that is not the documented shape is the same disagreement between
            // the announcement and the service as an announced-then-404 surface, and §8
            // spends that row saying such a disagreement is never a breakdown.
            return .unavailable(.surfaceNotServed(Self.eventsFeature))
        }
        return .page(EventPage(epoch: payload.epoch,
                               latestID: payload.latest_id,
                               events: payload.events.map(\.decoded),
                               hasMore: payload.has_more))
    }

    // MARK: metrics (§7)

    /// The largest number of grid slots this client will materialise. Not a step table in
    /// disguise — the contract's widest window is 2 016 points — but a guard against a body
    /// announcing `step_s: 1` over a year, which would have this allocate a billion slots
    /// for every absent series before anything could reject it.
    private static let maximumPoints = 100_000

    public func metrics(of machine: Machine, range: MetricsRange) async -> MetricsOutcome {
        let query = [URLQueryItem(name: "range", value: range.rawValue)]
        guard let url = Self.endpoint("metrics", on: machine, query: query) else {
            return .unreachable("no API address can be derived from the ssh target of \(machine.name)")
        }
        let reply: HTTPReply
        do {
            reply = try await fetch(url)
        } catch {
            if Self.isCancellation(error) { return .cancelled }
            return .unreachable(describe(error))
        }
        switch reply.status {
        case 200:
            break
        case 400, 404:
            // 404 is §8's "announced in `features` but answering 404" — never a breakdown.
            // 400 joins it rather than falling to `default`: this client only ever sends
            // the four documented values, so a refusal means the server does not know one
            // of them. §8 forbids retrying that as-is and points at an update, which is
            // what `surfaceNotServed` says; `unreachable` would retry it for ever.
            return .unavailable(.surfaceNotServed(Self.metricsFeature))
        default:
            return .unreachable("HTTP \(reply.status)")
        }
        guard let payload = try? JSONDecoder().decode(MetricsPayload.self, from: reply.body),
              let window = Self.window(from: payload) else {
            // Same disagreement between the announcement and the service as a 404 on an
            // announced surface, and §8 spends a row saying that is never a breakdown.
            return .unavailable(.surfaceNotServed(Self.metricsFeature))
        }
        return .window(window)
    }

    /// The grid check of §7 — and it checks **internal coherence only**: `to > from`,
    /// `step_s > 0`, `(to - from)` an exact multiple of it, and every *known* series exactly
    /// `(to - from) / step_s` long. Never a comparison against 60/300/3600/86400: the served
    /// grid is what makes the instants, and the client does not resample.
    ///
    /// Returns nil for a body that is not the contract's, which §8 files under "announced
    /// but discordant" — a surface that is not served, never a failing machine.
    private static func window(from payload: MetricsPayload) -> MetricsWindow? {
        guard let range = MetricsRange(rawValue: payload.range),
              payload.step_s > 0, payload.to > payload.from
        else { return nil }
        // A discordant body — one whose `to`/`from` are near Int64's bounds — must not
        // trap the process. `to > from` above rules out a *negative* span, not an
        // *overflowing* one: reporting overflow rather than subtracting keeps this in the
        // same "announced but discordant" bucket as every other malformed payload (§8),
        // instead of crashing the app and the CLI on a server that misbehaves.
        let (span, overflowed) = payload.to.subtractingReportingOverflow(payload.from)
        guard !overflowed, span % Int64(payload.step_s) == 0 else { return nil }
        let count = Int(span / Int64(payload.step_s))
        guard count > 0, count <= maximumPoints else { return nil }

        // A series absent from the body is exactly one that is entirely null (§7): four
        // cards always, an empty one rather than a missing one. A series that *is* there
        // and does not fit the grid is a body that is not the contract's. A key this
        // version does not know is ignored, and never length-checked.
        func decoded(_ kind: MetricKind) -> MetricSeries? {
            let points = payload.series[kind.rawValue] ?? Array(repeating: nil, count: count)
            guard points.count == count else { return nil }
            return MetricSeries(kind: kind, points: points)
        }
        guard let cpu = decoded(.cpu), let memory = decoded(.memory),
              let disk = decoded(.disk), let temperature = decoded(.temperature)
        else { return nil }

        return MetricsWindow(epoch: payload.epoch, range: range, stepS: payload.step_s,
                             from: Date(timeIntervalSince1970: TimeInterval(payload.from)),
                             to: Date(timeIntervalSince1970: TimeInterval(payload.to)),
                             cpu: cpu, memory: memory, disk: disk, temperature: temperature)
    }

    /// `URLError`'s `localizedDescription` alone drops the code, and the code is what makes
    /// two indistinguishable "The request timed out" reports tellable apart in a bug report.
    private func describe(_ error: Error) -> String {
        let nserror = error as NSError
        if let hpm = error as? HPMError { return hpm.message }
        return "\(nserror.localizedDescription) (\(nserror.domain) \(nserror.code))"
    }

    /// A cancelled fetch is the caller's own task going away — a tab switch mid-fetch, a
    /// deallocated feed — never a signal about the machine. `URLSession` surfaces it as
    /// either flavour depending on when the cancellation lands.
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }
}

// MARK: - Wire shapes

/// §4. Every field but `server` is required: `Decodable` synthesis refusing a missing or
/// mistyped one is precisely the "treated exactly like a 404" rule, enforced by the type
/// rather than by a hand-written check that could drift from it.
private struct CapabilitiesPayload: Decodable {
    let contract: String
    let server: String?
    let epoch: String
    let features: [String]
}

/// §6. `latest_id` and `has_more` keep the wire spelling: the contract's own names are
/// what a reader compares this against, and a `CodingKeys` block that renamed them would
/// put one more thing between the document and the code.
private struct EventsPayload: Decodable {
    let epoch: String
    let latest_id: Int64
    let events: [EventPayload]
    let has_more: Bool

    struct EventPayload: Decodable {
        let id: Int64
        let ts: Int64
        let kind: String
        let severity: String
        let subject: String
        let detail: String?

        var decoded: HomeportEvent {
            HomeportEvent(id: id,
                          timestamp: Date(timeIntervalSince1970: TimeInterval(ts)),
                          kind: kind,
                          severity: EventSeverity(apiValue: severity),
                          subject: subject,
                          detail: detail)
        }
    }
}

/// §7. `step_s` keeps its wire spelling for the same reason `latest_id` does: the contract's
/// own names are what a reader checks this against.
private struct MetricsPayload: Decodable {
    let epoch: String
    let range: String
    let step_s: Int
    let from: Int64
    let to: Int64
    /// Decoded as arrays of optionals so a `null` stays an absence and a string — which §7
    /// forbids — fails the decode instead of being folded into one.
    let series: [String: [Double?]]
}
