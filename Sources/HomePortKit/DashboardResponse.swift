import Foundation

/// Whether a dashboard navigation's response is an HTTP error — the check WebKit itself
/// does not make: `WKNavigationDelegate.didCommit` fires for any response that has a body,
/// a 500 (Homeport's own default error page, seen during a deploy's version-skew window)
/// included. Without this, a transient server error commits like a normal page load and
/// stays cached as "successfully loaded" for the rest of the app's lifetime.
///
/// A non-HTTP response (e.g. a `file:` load) has no status to fail on, so it is never an
/// error here.
public func isHTTPErrorResponse(_ response: URLResponse) -> Bool {
    guard let http = response as? HTTPURLResponse else { return false }
    return http.statusCode >= 400
}
