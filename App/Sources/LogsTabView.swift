import SwiftUI
import AppKit
import Combine
import HomePortKit

/// One log session per machine, owned by the window's root view — same doctrine as
/// `DashboardWebCache`: `MachineDetailView` carries `.id(machine.name)` and is recreated on
/// every machine switch, so a session held there would lose its buffer, its filter and its
/// follow state at each hop. Entries live exactly as long as the machine stays declared in
/// fleet.yaml, and an evicted one is stopped before it is dropped: no ssh survives a machine
/// removed from the inventory.
///
/// `sessions` is deliberately *not* `@Published`. `entry(for:)` is called from `body`, and a
/// published mutation there would publish changes from within a view update.
@MainActor
final class LogSessionStore: ObservableObject {
    private var sessions: [String: LogSession] = [:]
    private var terminationObserver: NSObjectProtocol?

    /// Quitting is the one exit none of the other paths cover: `NSApp.terminate` fires no
    /// `onDisappear`, orders no window out and runs no `deinit`, and a child `ssh` is
    /// reparented rather than killed. A follow on a quiet unit writes nothing, so it never
    /// takes the SIGPIPE that closing our end of its stdout would otherwise deliver, and it
    /// outlives the app for as long as the journal stays silent.
    ///
    /// `queue: nil` and not `.main`: a non-nil queue *enqueues* the block as an operation,
    /// and `NSApp.terminate` posts this notification and then exits without another runloop
    /// turn — the operation would simply be dropped. With `nil` the block runs synchronously
    /// on the posting thread, which for `willTerminate` is the main one, and that is what
    /// makes the `assumeIsolated` below true by construction rather than by luck.
    init() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAll() }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    func entry(for name: String) -> LogSession {
        if let existing = sessions[name] { return existing }
        let session = LogSession()
        sessions[name] = session
        return session
    }

    func prune(keeping names: [String]) {
        for (name, session) in sessions where !names.contains(name) {
            session.stop()
        }
        sessions = sessions.filter { names.contains($0.key) }
    }

    /// Every session down, the entries kept: this runs at quit, where the store outliving
    /// its sessions no longer matters but a surviving `ssh` does.
    func stopAll() {
        for session in sessions.values { session.stop() }
    }
}

/// The state of one machine's Logs tab, and the owner of its ssh process.
///
/// Two notions live here and are never confused. `followEnabled` is the user's intent and it
/// owns the process lifetime: on means a stream runs, off means the process is stopped and
/// the buffer stays. `pinnedToBottom` governs nothing but the auto-scroll — the stream keeps
/// running and lines keep arriving while the user reads further up.
///
/// The buffer is always the product of exactly one remote command: every mode change
/// *replaces* it. `journalctl -n N -f` serves the history and then follows, so stitching a
/// one-shot and a follow together would duplicate those N lines; nothing here deduplicates
/// or reasons about gaps.
@MainActor
final class LogSession: ObservableObject {
    /// The text filter. Applied to the rendering, never to the buffer — clearing it restores
    /// every line already received.
    @Published var filter = "" {
        didSet {
            guard filter != oldValue else { return }
            rebuild()
        }
    }
    @Published private(set) var followEnabled = true
    /// Derived from geometry alone: is the end anchor visible? There is no flag telling a
    /// programmatic scroll from a user one, because the rule never needs to know.
    @Published var pinnedToBottom = true
    @Published private(set) var loading = false
    /// Machine content — an exit code, ssh's own words. Shown mono, never translated.
    @Published private(set) var failure: String?
    /// The follow ended on its own: the link dropped, or the remote command died. Distinct
    /// from `failure`, which may be empty even then.
    @Published private(set) var interrupted = false
    /// The visible lines, laid out once per published batch rather than once per view body:
    /// a thousand lines of attributed text is not something to rebuild on every frame.
    @Published private(set) var rendered = AttributedString()
    @Published private(set) var isEmpty = true
    @Published private(set) var hasVisibleLines = false
    /// Identity of the last visible line — what tells the viewer "new lines arrived" apart
    /// from "the same lines were re-rendered".
    @Published private(set) var lastLineID: Int?

    private var buffer = LogBuffer()
    private var stream: ProcessOutputStream?
    private var task: Task<Void, Never>?
    /// Lines received but not yet published. Batching is what keeps a chatty unit from
    /// re-laying out the whole viewer on every single line.
    private var pending: [String] = []
    private var flushScheduled = false
    private var active = false
    /// Set only when the window took this session down while the tab was still on screen —
    /// what tells a resume apart from a machine the user simply navigated away from.
    private var suspendedByWindow = false

    private static let flushInterval: UInt64 = 300_000_000

    /// The last net under every caller's discipline: a session released without a prune, a
    /// deactivate or a window suspension must still take its ssh down with it.
    deinit {
        task?.cancel()
        stream?.stop()
    }

    // MARK: - Lifecycle

    /// The tab became visible. The stream only ever runs while it is: a Logs tab left behind
    /// must not keep an ssh alive.
    func activate(model: FleetModel, machine: Machine) {
        guard !active else { return }
        active = true
        guard followEnabled else { return }
        start(follow: true, model: model, machine: machine)
    }

    /// The tab went away: the process stops, the buffer, the filter and the follow intent
    /// stay — coming back resumes where it left off.
    func deactivate() {
        active = false
        suspendedByWindow = false
        stop()
    }

    /// The window was ordered out from under a visible tab. Same stop, but remembered, so
    /// that reopening resumes this session and only this one.
    func suspendForWindow() {
        guard active else { return }
        active = false
        suspendedByWindow = true
        stop()
    }

    func resumeAfterWindow(model: FleetModel, machine: Machine) {
        guard suspendedByWindow else { return }
        suspendedByWindow = false
        activate(model: model, machine: machine)
    }

    func setFollow(_ on: Bool, model: FleetModel, machine: Machine) {
        guard on != followEnabled else { return }
        followEnabled = on
        if on {
            start(follow: true, model: model, machine: machine)
        } else {
            stop()
        }
    }

    /// The one-shot, offered only while the follow is off — following *is* refreshing.
    func refresh(model: FleetModel, machine: Machine) {
        start(follow: false, model: model, machine: machine)
    }

    /// Retry restarts whichever mode is currently intended.
    func retry(model: FleetModel, machine: Machine) {
        start(follow: followEnabled, model: model, machine: machine)
    }

    func stop() {
        task?.cancel()
        task = nil
        stream?.stop()
        stream = nil
        flushNow()
        loading = false
        // Cleared here rather than in `start`: every path that ends or replaces a read goes
        // through `stop`, so no notice about a follow that died can outlive the follow it
        // described — including the one the user turned off by hand.
        interrupted = false
    }

    // MARK: - Reading

    private func start(follow: Bool, model: FleetModel, machine: Machine) {
        stop()
        failure = nil
        loading = true
        pinnedToBottom = true
        pending.removeAll()
        buffer.reset()
        rebuild()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            if follow {
                await self.runFollow(model: model, machine: machine)
            } else {
                await self.runSnapshot(model: model, machine: machine)
            }
        }
    }

    private func runFollow(model: FleetModel, machine: Machine) async {
        let stream: ProcessOutputStream
        do {
            stream = try await model.startLogFollow(for: machine, lines: LogDefaults.tail)
        } catch {
            guard !Task.isCancelled else { return }
            loading = false
            failure = "\(error)"
            return
        }
        guard !Task.isCancelled else {
            stream.stop()
            return
        }
        self.stream = stream
        // The command is up. A unit that logs nothing must reach its empty state instead of
        // spinning forever waiting for a first line that will never come.
        loading = false
        for await line in stream.lines {
            // An `AsyncStream` still delivers what it had buffered after `finish()`, so a
            // cancelled follow can be handed lines belonging to the command it replaced.
            // Appending them would break the one invariant of this buffer: it is the product
            // of exactly one remote command, never a stitching of two.
            guard !Task.isCancelled else { break }
            pending.append(line)
            scheduleFlush()
        }
        guard !Task.isCancelled else { return }
        flushNow()
        self.stream = nil
        // journalctl -f does not end by itself: reaching here means the link or the remote
        // command died. The buffer already received stays on screen, and `followEnabled` is
        // left alone — it carries the user's intent, and a link that dropped is not the user
        // changing their mind. `interrupted` is what says the intent is currently unserved,
        // and Retry restarts the follow rather than falling back to a one-shot.
        interrupted = true
        failure = stream.failure
    }

    private func runSnapshot(model: FleetModel, machine: Machine) async {
        do {
            let text = try await model.logSnapshot(for: machine, lines: LogDefaults.tail)
            guard !Task.isCancelled else { return }
            buffer.append(splitLogLines(text))
            rebuild()
        } catch {
            guard !Task.isCancelled else { return }
            failure = "\(error)"
        }
        loading = false
    }

    // MARK: - Batching

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.flushInterval)
            self?.flushNow()
        }
    }

    private func flushNow() {
        flushScheduled = false
        guard !pending.isEmpty else { return }
        buffer.append(pending)
        pending.removeAll()
        rebuild()
    }

    // MARK: - Rendering

    /// One attributed string for the whole viewer: SwiftUI's selection does not cross two
    /// `Text` views, and AC 1 asks for a selection that spans lines. Colour therefore has to
    /// travel as a run attribute, and it is set on *every* run — a view-level foreground
    /// style would win over the run attributes and quietly untint every error line.
    private func rebuild() {
        let visible = filterLogLines(buffer.lines, matching: filter)
        isEmpty = buffer.lines.isEmpty
        hasVisibleLines = !visible.isEmpty
        lastLineID = visible.last?.id
        var text = AttributedString()
        for (index, line) in visible.enumerated() {
            var run = AttributedString(line.text)
            run.foregroundColor = line.isError ? Theme.semanticCritical : Theme.ink
            text.append(run)
            if index < visible.count - 1 {
                var separator = AttributedString("\n")
                separator.foregroundColor = Theme.ink
                text.append(separator)
            }
        }
        rendered = text
    }
}

/// The Logs tab (FR4): the last lines of the machine's service journal, followed
/// continuously, filtered, selectable across lines, with the error lines tinted.
struct LogsTabView: View {
    @ObservedObject var model: FleetModel
    @ObservedObject var commands: ControlCenterCommands
    @ObservedObject var session: LogSession
    let machine: Machine

    @FocusState private var filterFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            controls
            if session.interrupted, !session.isEmpty {
                interruptedNotice
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: commands.signal) { signal in
            if signal?.command == .focusFilter { filterFocused = true }
        }
        // ⌘F belongs to this tab only while it shows; the fleet view claims the same command
        // when it is the one on screen.
        .onAppear {
            commands.handling(.focusFilter, true)
            session.activate(model: model, machine: machine)
        }
        .onDisappear {
            commands.handling(.focusFilter, false)
            session.deactivate()
        }
        // Closing the window is not a disappearance: this is a hand-built `NSWindow` with
        // `isReleasedWhenClosed = false`, so it is merely ordered out and SwiftUI keeps the
        // hierarchy — and with it, without these two, an ssh following a journal no one is
        // reading. Reopening has to resume for the same reason: `onAppear` will not fire a
        // second time either. Both calls are guarded on the session side, so a window that
        // simply regains focus starts nothing.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            guard note.object is ControlCenterNSWindow else { return }
            session.suspendForWindow()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard note.object is ControlCenterNSWindow else { return }
            session.resumeAfterWindow(model: model, machine: machine)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: Theme.Spacing.xs) {
            // A pill rather than a `Toggle`: a system switch would put the only accent
            // colour of the app in the middle of a monochrome chrome. Selected reads as an
            // ink surface here, exactly like the tab pills right above it.
            Button {
                session.setFollow(!session.followEnabled, model: model, machine: machine)
            } label: {
                Text("Follow")
            }
            .buttonStyle(TabPillStyle(selected: session.followEnabled))
            // The long form belongs to `.help` alone. Overriding the accessibility label with
            // it would hide the visible word from Voice Control, which matches what is drawn.
            .help(Text("Follow the log continuously"))
            .accessibilityAddTraits(session.followEnabled ? [.isSelected] : [])
            // Nothing to refresh while following: the lines arrive on their own.
            if !session.followEnabled {
                Button { session.refresh(model: model, machine: machine) } label: { Text("Refresh") }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .disabled(session.loading)
                    .help(Text("Reload the last lines"))
            }
            Spacer(minLength: Theme.Spacing.md)
            filterField
        }
    }

    private var filterField: some View {
        FilterField(text: $session.filter,
                    prompt: "Filter log lines",
                    accessibility: "Filter log lines",
                    hint: "Filter log lines (⌘F)",
                    focus: $filterFocused)
    }

    // MARK: - Content

    /// The guards in order: nothing on screen and a read in flight; nothing on screen and a
    /// verdict; nothing at all; nothing matching; the log. A read that failed is always an
    /// empty state with a way out, never a raw trace.
    @ViewBuilder
    private var content: some View {
        if session.loading, session.isEmpty {
            loadingState
        } else if session.isEmpty, session.failure != nil || session.interrupted {
            EmptyStateView(
                title: "Unreachable",
                message: "\(machine.name) is unreachable. Check Tailscale or retry.",
                detail: session.failure,
                actionTitle: "Retry", action: retry)
        } else if session.isEmpty {
            EmptyStateView(
                title: "No log lines",
                message: "The service journal of \(machine.name) has nothing to show yet.")
        } else if !session.hasVisibleLines {
            EmptyStateView(
                title: "No line matches",
                message: "No line of this log matches the filter.",
                actionTitle: "Clear the filter",
                action: { session.filter = "" })
        } else {
            LogViewer(text: session.rendered, lastLineID: session.lastLineID,
                      following: session.followEnabled,
                      pinnedToBottom: $session.pinnedToBottom)
        }
    }

    private var loadingState: some View {
        HStack(spacing: Theme.Spacing.xs) {
            ProgressView().controlSize(.small)
            Text("Loading…")
                .styled(Theme.body)
                .foregroundStyle(Theme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.xl)
        .background(Theme.surfaceSoft, in: RoundedRectangle(cornerRadius: Theme.Rounded.lg))
    }

    /// The follow died with lines already on screen: say so above them and offer the way
    /// back, rather than replacing what was read with an error page.
    private var interruptedNotice: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            HStack(spacing: Theme.Spacing.sm) {
                Text("Log follow stopped")
                    .styled(Theme.bodyStrong)
                    .foregroundStyle(Theme.semanticWarning)
                Button(action: retry) { Text("Retry") }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .accessibilityLabel(Text("Retry"))
            }
            if let failure = session.failure {
                Text(verbatim: failure)
                    .styled(Theme.data)
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(Theme.data.lineSpacing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.md)
        .background(Theme.surfaceSoft, in: RoundedRectangle(cornerRadius: Theme.Rounded.md))
    }

    /// One gesture restarts the read and re-polls the machine — the same pairing the
    /// dashboard's Retry uses.
    private func retry() {
        session.retry(model: model, machine: machine)
        model.refresh()
    }
}

/// The `log-viewer` token: soft surface, mono, one single `Text`.
///
/// One `Text` and not a `LazyVStack` of them, because a selection has to run from one line to
/// the next and SwiftUI's selection does not cross two `Text` views. That is also what fixes
/// the buffer cap: the whole log is laid out, nothing is lazy.
private struct LogViewer: View {
    let text: AttributedString
    let lastLineID: Int?
    /// Resuming a follow only means something while one runs: with the follow off, nothing
    /// is chasing the bottom of the buffer and the button would name an action that has no
    /// referent. Scrolling stays free either way.
    let following: Bool
    @Binding var pinnedToBottom: Bool

    private static let bottomAnchor = "log-viewer-bottom"
    private static let space = "log-viewer-space"
    /// How close to the end still counts as "at the end".
    private static let slack: CGFloat = 12

    var body: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(text)
                            .themeFont(Theme.data)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        // The end anchor: what the scroll targets, and the single geometry
                        // measurement `pinnedToBottom` is derived from.
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchor)
                            .background(GeometryReader { geometry in
                                Color.clear.preference(
                                    key: BottomOffsetKey.self,
                                    value: geometry.frame(in: .named(Self.space)).maxY)
                            })
                    }
                    .padding(Theme.Spacing.sm)
                }
                .coordinateSpace(name: Self.space)
                .onPreferenceChange(BottomOffsetKey.self) { offset in
                    let pinned = offset <= outer.size.height + Self.slack
                    if pinned != pinnedToBottom { pinnedToBottom = pinned }
                }
                // Auto-scroll is conditioned on position, never on the origin of the scroll:
                // at each batch, follow the end if the end was already in view.
                .onChange(of: lastLineID) { _ in
                    guard pinnedToBottom else { return }
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
                .onAppear { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
                // Resuming re-pins and goes back down. It restarts nothing: the stream never
                // stopped running while the user was reading further up.
                .overlay(alignment: .bottom) {
                    if following, !pinnedToBottom {
                        Button {
                            pinnedToBottom = true
                            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                        } label: {
                            Text("Jump to latest")
                        }
                        .buttonStyle(PillButtonStyle(kind: .primary))
                        .padding(Theme.Spacing.sm)
                        .accessibilityLabel(Text("Jump to latest"))
                    }
                }
            }
        }
        .background(Theme.surfaceSoft, in: RoundedRectangle(cornerRadius: Theme.Rounded.md))
    }
}

private struct BottomOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
