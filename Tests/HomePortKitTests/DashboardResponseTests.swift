import XCTest
@testable import HomePortKit

final class DashboardResponseTests: XCTestCase {
    private func response(status: Int) -> URLResponse {
        HTTPURLResponse(url: URL(string: "http://raspyellow/")!, statusCode: status,
                         httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    func testOKIsNotAnError() {
        XCTAssertFalse(isHTTPErrorResponse(response(status: 200)))
    }

    func testRedirectIsNotAnError() {
        XCTAssertFalse(isHTTPErrorResponse(response(status: 302)))
    }

    /// The exact bug: Homeport's own default 500 body, served during a deploy's
    /// version-skew window, must be flagged rather than treated as a loaded page.
    func testInternalServerErrorIsAnError() {
        XCTAssertTrue(isHTTPErrorResponse(response(status: 500)))
    }

    func testNotFoundIsAnError() {
        XCTAssertTrue(isHTTPErrorResponse(response(status: 404)))
    }

    /// The boundary is inclusive at 400 — the first client-error status.
    func testStatusBoundary() {
        XCTAssertFalse(isHTTPErrorResponse(response(status: 399)))
        XCTAssertTrue(isHTTPErrorResponse(response(status: 400)))
    }

    /// A non-HTTP response (e.g. a `file:` load) has no status code to fail on.
    func testNonHTTPResponseIsNotAnError() {
        let response = URLResponse(url: URL(string: "file:///tmp/x")!, mimeType: nil,
                                    expectedContentLength: 0, textEncodingName: nil)
        XCTAssertFalse(isHTTPErrorResponse(response))
    }
}
