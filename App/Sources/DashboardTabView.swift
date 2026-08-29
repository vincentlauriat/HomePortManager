import SwiftUI
import AppKit
import WebKit
import HomePortKit

/// One live `WKWebView` per machine, owned by the window's root view so page state —
/// scroll, form input, internal navigation — survives tab and machine switches, which a
/// sheet-local `@State` cannot (`MachineDetailView` carries `.id(machine.name)`). Entries
/// follow the same doctrine as `FleetModel.reloadFleet`'s dictionaries: keyed state lives
/// exactly as long as the machine stays declared in fleet.yaml.
@MainActor
final class DashboardWebCache: ObservableObject {
    /// A machine's web view plus its navigation verdict. The failure state lives here,
    /// not in the tab view: the view is recreated on every selection, the verdict must not
    /// reset with it.
    @MainActor
    final class Entry: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
        let webView: WKWebView
        /// WebKit's error, kept as produced — machine content, shown mono, never translated.
        @Published var loadFailure: String?
        /// True once a page committed. From then on the page is the display, whatever the
        /// reachability says — UX-DR5 keeps the last data on screen.
        @Published var hasContent = false
        /// A load is in flight and nothing is rendered yet — the tailnet can be slow, and
        /// a mute blank view reads as broken. Driven from delegate callbacks, never from a
        /// view update.
        @Published var isLoading = false
        /// The dashboard URL of the last requested load — what internal navigation is
        /// measured against, and what detects an identity edited in fleet.yaml.
        private var requestedURL: URL?
        /// A `start` is scheduled but has not run yet. The web view is not loading during
        /// that gap, so without this the direct-load path below would fire a request the
        /// scheduled `start` then immediately supersedes.
        private var pendingStart = false

        override init() {
            webView = WKWebView()
            super.init()
            webView.navigationDelegate = self
            webView.uiDelegate = self
        }

        /// First load only: a failed or already-loaded page never reloads behind the
        /// user's back — that is what Retry is for. Except when the address itself moved
        /// (ssh or port edited in fleet.yaml while this page was cached): the old page no
        /// longer belongs to this machine's identity and reloads. The identity is claimed
        /// synchronously — repeated view updates in one layout cycle must not stack loads —
        /// but `start` is deferred off the current runloop turn: this is called from a
        /// view update, and `start` resets published state.
        func loadIfNeeded(_ url: URL) {
            if requestedURL != url {
                requestedURL = url
                pendingStart = true
                Task { @MainActor [weak self] in self?.start(url) }
                return
            }
            guard !pendingStart, !hasContent, !webView.isLoading, loadFailure == nil else { return }
            webView.load(URLRequest(url: url))
        }

        func retry(_ url: URL) {
            start(url)
        }

        private func start(_ url: URL) {
            pendingStart = false
            requestedURL = url
            hasContent = false
            loadFailure = nil
            webView.load(URLRequest(url: url))
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            isLoading = true
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            hasContent = true
            loadFailure = nil
            isLoading = false
        }

        /// WebKit commits any response with a body, a 500 included — `didCommit` alone
        /// cannot tell Homeport's own error page from a real dashboard. Checked here,
        /// before commit, so a server error is refused instead of cached as loaded.
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if navigationResponse.isForMainFrame, isHTTPErrorResponse(navigationResponse.response) {
                let status = (navigationResponse.response as? HTTPURLResponse)?.statusCode ?? 0
                isLoading = false
                loadFailure = "HTTP \(status): \(HTTPURLResponse.localizedString(forStatusCode: status))"
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        /// New-window navigations (`target="_blank"`, `window.open`) never reach
        /// `decidePolicyFor`: without a UI delegate WebKit drops them silently and the
        /// click does nothing. The embedded view has no tabs — hand them to the default
        /// browser instead, same exit as an external link.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let target = navigationAction.request.url {
                openExternally(target)
            }
            return nil
        }

        /// Hands a page-supplied URL to the system — so only the schemes a dashboard link
        /// legitimately carries. Remote content loaded over plain HTTP must not be able to
        /// reach `file:`, `javascript:` or any app scheme registered on this Mac through
        /// `NSWorkspace`; those are dropped, and the click simply does nothing.
        private func openExternally(_ target: URL) {
            switch target.scheme?.lowercased() {
            case "http", "https", "mailto": NSWorkspace.shared.open(target)
            default: break
            }
        }

        /// Internal navigation stays embedded; a link the user clicks toward any other
        /// host leaves for the default browser — without an address bar or back button,
        /// the embedded view would otherwise strand them there. Same host on any port is
        /// still the machine; a `mailto:` link has no host and leaves like any other.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let target = navigationAction.request.url,
               target.host?.lowercased() != requestedURL?.host?.lowercased() {
                decisionHandler(.cancel)
                openExternally(target)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            fail(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            fail(error)
        }

        /// A crashed WebContent process would otherwise leave a dead blank page with no
        /// verdict and no Retry — exactly the dead page UX-DR5 forbids.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            hasContent = false
            isLoading = false
            loadFailure = "WebKit: web content process terminated"
        }

        /// A cancelled navigation is not a verdict: Retry itself interrupts the previous
        /// provisional load, and WebKit's "frame load interrupted" (102) is the same
        /// artefact — reporting either would flash a false failure. Nothing is touched on
        /// those paths, spinner included: the cancelled load's report arrives *after* the
        /// navigation that replaced it started, so clearing `isLoading` here would blank
        /// the spinner of a load still in flight.
        private func fail(_ error: Error) {
            let nserror = error as NSError
            if nserror.domain == NSURLErrorDomain, nserror.code == NSURLErrorCancelled { return }
            if nserror.domain == "WebKitErrorDomain", nserror.code == 102 { return }
            isLoading = false
            loadFailure = "\(nserror.localizedDescription) (\(nserror.domain) \(nserror.code))"
        }
    }

    private var entries: [String: Entry] = [:]

    func entry(for name: String) -> Entry {
        if let existing = entries[name] { return existing }
        let entry = Entry()
        entries[name] = entry
        return entry
    }

    /// Called when the declared machine names change: a machine removed from fleet.yaml
    /// must not keep a live web view behind the scenes.
    func prune(keeping names: [String]) {
        entries = entries.filter { names.contains($0.key) }
    }
}

/// The Dashboard tab (FR3): the machine's Homeport web dashboard, embedded and usable in
/// the window. Guarded by the UX-DR5 empty-states — a WebKit error page is never shown.
struct DashboardTabView: View {
    @ObservedObject var model: FleetModel
    let cache: DashboardWebCache
    let machine: Machine

    var body: some View {
        if let url = dashboardURL(for: machine) {
            DashboardContent(model: model, entry: cache.entry(for: machine.name),
                             machine: machine, url: url)
        } else {
            // Retrying cannot fix an address that cannot exist: no button here.
            EmptyStateView(
                title: "No dashboard address",
                message: "No web address can be derived from the ssh target of \(machine.name). Fix its entry in fleet.yaml.")
        }
    }
}

/// The three display guards, in the spec's order: known-unreachable with nothing loaded
/// short-circuits before any request is made; a navigation failure shows its verdict; the
/// page otherwise. Both verdicts are subordinate to `hasContent`: a page that committed
/// stays on screen — whether the machine goes unreachable or a later navigation fails —
/// because UX-DR5 keeps the last data. Retry clears `hasContent` first, so a retry that
/// fails does surface its verdict.
private struct DashboardContent: View {
    @ObservedObject var model: FleetModel
    @ObservedObject var entry: DashboardWebCache.Entry
    let machine: Machine
    let url: URL

    var body: some View {
        if model.statuses[machine.name]?.reachable == false, !entry.hasContent {
            EmptyStateView(
                title: "Unreachable",
                message: "\(machine.name) is unreachable. Check Tailscale or retry.",
                actionTitle: "Retry", action: retry)
        } else if let failure = entry.loadFailure, !entry.hasContent {
            EmptyStateView(
                title: "Dashboard did not load",
                message: "The dashboard of \(machine.name) did not respond. Check that Homeport is running, then retry.",
                detail: failure,
                actionTitle: "Retry", action: retry)
        } else {
            DashboardWebView(entry: entry, url: url)
                // Nothing rendered yet and a load in flight: a spinner over the blank
                // view, gone as soon as the first content commits.
                .overlay {
                    if entry.isLoading, !entry.hasContent {
                        ProgressView().controlSize(.small)
                    }
                }
        }
    }

    /// One gesture refreshes both: the page reloads and the status re-polls.
    private func retry() {
        entry.retry(url)
        model.refresh()
    }
}

private struct DashboardWebView: NSViewRepresentable {
    let entry: DashboardWebCache.Entry
    let url: URL

    func makeNSView(context: Context) -> WKWebView { entry.webView }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        entry.loadIfNeeded(url)
    }
}
