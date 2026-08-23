import XCTest
@testable import HomePortKit

final class DashboardURLTests: XCTestCase {
    private func url(ssh: String, port: Int = 80) -> String? {
        dashboardURL(for: Machine(name: "m", ssh: ssh, port: port))?.absoluteString
    }

    // The exact URL form is pinned: scheme, host, explicit port, root path.

    func testUserAtHost() {
        XCTAssertEqual(url(ssh: "pi@raspyellow", port: 8080), "http://raspyellow:8080/")
    }

    func testBareHost() {
        XCTAssertEqual(url(ssh: "raspyellow", port: 8080), "http://raspyellow:8080/")
    }

    func testCustomPort() {
        XCTAssertEqual(url(ssh: "admin@pi.local", port: 3000), "http://pi.local:3000/")
    }

    func testExplicitPort80() {
        XCTAssertEqual(url(ssh: "pi@raspyellow", port: 80), "http://raspyellow:80/")
    }

    /// The host is what follows the *last* @ — an ssh user may itself contain one.
    func testHostAfterLastAt() {
        XCTAssertEqual(url(ssh: "user@corp@raspyellow", port: 80), "http://raspyellow:80/")
    }

    func testEmptySSHYieldsNil() {
        XCTAssertNil(url(ssh: ""))
    }

    func testDanglingUserYieldsNil() {
        XCTAssertNil(url(ssh: "user@"))
    }

    func testHostWithSpaceYieldsNil() {
        XCTAssertNil(url(ssh: "pi@rasp yellow"))
    }

    /// A `host:port` suffix or a bare IPv6 literal is not a fleet.yaml identity — and
    /// must yield nil rather than a syntactically valid URL naming the wrong thing.
    func testHostWithColonYieldsNil() {
        XCTAssertNil(url(ssh: "pi@raspyellow:2222"))
        XCTAssertNil(url(ssh: "::1"))
    }

    /// Brackets are `urlHostAllowed` too: a bracketed IPv6 literal (or any stray
    /// bracket) must yield nil, like the bare `:` form.
    func testHostWithBracketsYieldsNil() {
        XCTAssertNil(url(ssh: "pi@[::1]"))
        XCTAssertNil(url(ssh: "pi@rasp[3]"))
    }

    /// URL sub-delimiters are `urlHostAllowed` as well: `URLComponents` would carry them
    /// into an address that names no machine, so the allowlist must refuse them.
    func testHostWithSubDelimitersYieldsNil() {
        XCTAssertNil(url(ssh: "pi@rasp&yellow"))
        XCTAssertNil(url(ssh: "pi@rasp,yellow"))
        XCTAssertNil(url(ssh: "pi@rasp;a=b"))
        XCTAssertNil(url(ssh: "pi@rasp+yellow"))
    }

    /// The DNS alphabet is what a host is made of: an IDN or any non-ASCII label is not
    /// a fleet.yaml identity and must not be percent-encoded into one.
    func testNonASCIIHostYieldsNil() {
        XCTAssertNil(url(ssh: "pi@raspberré"))
    }

    /// Hyphens and dots stay valid — the ordinary shape of a MagicDNS name.
    func testHyphenAndDotHostsStayValid() {
        XCTAssertEqual(url(ssh: "pi@rasp-yellow.tail1234.ts.net", port: 8080),
                       "http://rasp-yellow.tail1234.ts.net:8080/")
    }

    /// The `URLComponents.port` setter raises on a negative port: the guard must turn
    /// any out-of-range port into nil before it gets there.
    func testPortOutOfRangeYieldsNil() {
        XCTAssertNil(url(ssh: "pi@raspyellow", port: -1))
        XCTAssertNil(url(ssh: "pi@raspyellow", port: 0))
        XCTAssertNil(url(ssh: "pi@raspyellow", port: 65536))
    }

    /// The valid range is inclusive on both ends.
    func testPortBoundsAreValid() {
        XCTAssertEqual(url(ssh: "pi@raspyellow", port: 1), "http://raspyellow:1/")
        XCTAssertEqual(url(ssh: "pi@raspyellow", port: 65535), "http://raspyellow:65535/")
    }
}
