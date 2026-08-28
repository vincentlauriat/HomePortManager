import SwiftUI
import AppKit
import HomePortKit

/// The control center is a single window, opened from the menu bar and brought forward on
/// every later invocation. Hand-built as an `NSWindow` rather than declared as a `Window`
/// scene for the same reason `LogsWindow` is: an `LSUIElement` app must not open a window
/// at launch, and `contentMinSize` has to be pinned explicitly.
@MainActor
enum ControlCenterWindow {
    private static var window: ControlCenterNSWindow?

    static func open(model: FleetModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = ControlCenterNSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = String(localized: "Control Center")
        // `contentViewController`, not `contentView`: an `NSHostingView` set as the raw
        // content view fills the whole window frame, titlebar included, because SwiftUI has
        // no safe area to read there — the machine banner was drawn under the title bar and
        // clipped. A hosting *controller* lets AppKit lay the view out below the titlebar.
        window.contentViewController = NSHostingController(
            rootView: ControlCenterView(model: model, commands: window.commands))
        // AFTER `contentViewController`, never before: assigning it resets the window's
        // min/max content size, so a min pinned earlier is silently dropped and the window
        // can be dragged below 900x600 — which wraps the action pills onto three lines.
        window.contentMinSize = NSSize(width: Theme.Metrics.windowMinWidth,
                                       height: Theme.Metrics.windowMinHeight)
        window.setContentSize(NSSize(width: 1040, height: 680))
        // `Theme` is a light palette pinned in hex, and the spec rules dark mode out. Left to
        // inherit a dark system appearance the window gets a black title bar and paints every
        // strip the content does not cover in dark grey — which is what clipped the machine
        // banner. Pinning aqua makes the frame agree with the palette it hosts.
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        window.center()
        Self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Keyboard shortcuts are resolved by the window itself. An `LSUIElement` app has no main
/// menu, and SwiftUI's `.keyboardShortcut` is dispatched through the menu system — inside a
/// bare `NSHostingView` it never fires. Overriding `performKeyEquivalent` keeps ⌘R, ⌘F and
/// ⌘1…⌘8 scoped to this window and independent of the menu bar.
final class ControlCenterNSWindow: NSWindow {
    let commands = ControlCenterCommands()

    /// `true` only when the command was actually acted upon. A ⌘3 pressed on the fleet view
    /// has no tab to select: swallowing it would make the key silently dead, so it goes back
    /// up the responder chain instead.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let command = ControlCenterCommands.Command(event: event), commands.send(command) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The window's keyboard commands, published to whichever view owns each one: the split
/// view refreshes, the fleet view takes the filter focus, the machine sheet switches tab.
@MainActor
final class ControlCenterCommands: ObservableObject {
    enum Command: Equatable {
        case refresh
        case focusFilter
        case selectTab(Int)

        /// What a view has to be showing for a command to mean anything.
        enum Kind: Hashable {
            case refresh
            case focusFilter
            case selectTab
        }

        var kind: Kind {
            switch self {
            case .refresh: return .refresh
            case .focusFilter: return .focusFilter
            case .selectTab: return .selectTab
            }
        }

        /// `⌘R`, `⌘F`, `⌘1`…`⌘8` — command alone, so ⇧⌘R or ⌥⌘F stay available.
        ///
        /// Letters are read from the characters, digits from the *physical* key. The top row
        /// of an AZERTY keyboard produces `&`, `é`, `"`… and never `1`-`8`, so matching on
        /// characters made every ⌘1…⌘8 dead on the only keyboard this app is used with.
        init?(event: NSEvent) {
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            else { return nil }
            if let index = Command.digitKeys[event.keyCode] {
                self = .selectTab(index)
                return
            }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "r": self = .refresh
            case "f": self = .focusFilter
            default: return nil
            }
        }

        /// Virtual key codes of the digits 1…8, on the number row and on the numeric keypad.
        /// They are positions on the keyboard, identical on every layout — which is the
        /// whole point. (`kVK_ANSI_5` is 23 and `kVK_ANSI_6` is 22: not a typo.)
        private static let digitKeys: [UInt16: Int] = [
            18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8,
            83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8,
        ]
    }

    /// A command plus a sequence number: pressing the same key twice has to read as two
    /// distinct events, which a bare `Command` would not.
    struct Signal: Equatable {
        let command: Command
        let sequence: Int
    }

    @Published private(set) var signal: Signal?
    private var sequence = 0

    /// How many visible views can act on each kind of command. A count rather than a flag:
    /// SwiftUI can show the next view before the previous one disappears, and a flag would
    /// be cleared by the departing view right after the arriving one set it.
    private var handlers: [Command.Kind: Int] = [:]

    /// Called by a view for as long as it is on screen and able to act on `kind`.
    func handling(_ kind: Command.Kind, _ active: Bool) {
        handlers[kind, default: 0] += active ? 1 : -1
    }

    /// Sends the command, and says whether anything was listening. `⌘R` always is: the
    /// window's own split view refreshes the fleet whatever the detail column shows.
    @discardableResult
    func send(_ command: Command) -> Bool {
        guard command.kind == .refresh || handlers[command.kind, default: 0] > 0 else {
            return false
        }
        sequence += 1
        signal = Signal(command: command, sequence: sequence)
        return true
    }
}

/// What the detail column shows. The fleet entry is always present, even with no machines.
enum ControlCenterSelection: Hashable {
    case fleet
    case machine(String)
}

struct ControlCenterView: View {
    @ObservedObject var model: FleetModel
    @ObservedObject var commands: ControlCenterCommands
    @State private var selection: ControlCenterSelection = .fleet
    @FocusState private var focusedRow: ControlCenterSelection?
    /// Owned here, not by the machine sheet: `MachineDetailView` is recreated per machine
    /// (`.id(machine.name)`), and the dashboard web views must survive that.
    @StateObject private var webCache = DashboardWebCache()
    /// Same reason, same lifetime: a Logs tab's buffer, filter and follow intent belong to
    /// the window, not to the sheet `.id(machine.name)` throws away on each switch.
    @StateObject private var logSessions = LogSessionStore()
    /// Same ownership as the two above: an event feed must survive the tab view and the
    /// machine sheet, both of which SwiftUI recreates.
    @StateObject private var eventFeeds = EventFeedStore()

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(Theme.Metrics.sidebarWidth)
        } detail: {
            detail
                // Clears the unified-toolbar strip macOS draws over this column; SwiftUI
                // reports no safe area for it, so the offset has to be explicit.
                .padding(.top, Theme.Metrics.splitViewTopStrip)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Theme.canvas)
        }
        .navigationSplitViewStyle(.balanced)
        // A NavigationSplitView in a titled window reserves a window-toolbar strip above the
        // detail column and draws the material over it, clipping the machine banner. This
        // window has no toolbar items at all — the shortcuts live on the NSWindow — so the
        // strip is pure loss.
        .toolbar(.hidden, for: .windowToolbar)
        // The toast anchors on the window root, bottom right, whatever the detail shows.
        // Its dismissal timer lives in `FleetModel.showToast` — model lifetime, not view
        // lifetime, so a toast born before this window ever opened still expires. Purely
        // informational: it must never steal the clicks of whatever it covers.
        .overlay(alignment: .bottomTrailing) {
            if let toast = model.toast {
                ToastView(machine: toast.machine, message: toast.message)
                    .padding(Theme.Spacing.lg)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.default, value: model.toast)
        .onChange(of: commands.signal) { signal in
            if signal?.command == .refresh { model.refresh() }
        }
        .onChange(of: model.machines.map(\.name)) { names in
            // The selected machine was removed from fleet.yaml: fall back on the fleet
            // rather than keeping a selection that points at nothing. Its dashboard web
            // view dies with it, and its log session is stopped before being dropped —
            // cached state never outlives the declaration, and no ssh outlives fleet.yaml.
            webCache.prune(keeping: names)
            logSessions.prune(keeping: names)
            eventFeeds.prune(keeping: names)
            if case .machine(let name) = selection, !names.contains(name) {
                selection = .fleet
            }
        }
    }

    private var sidebar: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Button { selection = .fleet } label: {
                    SidebarRow(title: String(localized: "Fleet"), block: nil,
                               severity: nil, selected: selection == .fleet)
                }
                .buttonStyle(.plain)
                .focusable()
                .focused($focusedRow, equals: .fleet)
                // Selection is an ink surface here: the ring has to contrast with it.
                .focusRing(focusedRow == .fleet, cornerRadius: Theme.Rounded.sm,
                           onDark: selection == .fleet)
                .accessibilityLabel(Text("Fleet"))

                if model.machines.isEmpty {
                    // Never a mute empty sidebar: say why there is nothing under it.
                    Text("No machines declared")
                        .styled(Theme.body)
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, Theme.Spacing.sm)
                        .padding(.top, Theme.Spacing.sm)
                } else {
                    Text("MACHINES")
                        .styled(Theme.eyebrow)
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, Theme.Spacing.sm)
                        .padding(.top, Theme.Spacing.sm)
                }

                ForEach(rows) { row in
                    Button { selection = .machine(row.name) } label: {
                        SidebarRow(title: row.name, block: row.block, severity: row.severity,
                                   selected: selection == .machine(row.name))
                    }
                    .buttonStyle(.plain)
                    .focusable()
                    .focused($focusedRow, equals: .machine(row.name))
                    .focusRing(focusedRow == .machine(row.name), cornerRadius: Theme.Rounded.sm,
                               onDark: selection == .machine(row.name))
                    .accessibilityLabel(Text(verbatim: row.name))
                    .accessibilityValue(row.severity.accessibilityText)
                }
            }
            .padding(Theme.Spacing.xs)
        }
        .background(Theme.canvas)
    }

    private var rows: [FleetRow] { model.rows() }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .fleet:
            fleetOverview
        case .machine(let name):
            if let machine = model.machines.first(where: { $0.name == name }) {
                MachineDetailView(model: model, commands: commands, webCache: webCache,
                                  logSessions: logSessions, eventFeeds: eventFeeds,
                                  machine: machine)
                    // A fresh tab state per machine, so ⌘3 on one does not stick to the next.
                    .id(machine.name)
            } else {
                // The machine left fleet.yaml while it was selected.
                fleetOverview
            }
        }
    }

    private var fleetOverview: some View {
        FleetOverviewView(model: model, commands: commands,
                          select: { selection = .machine($0) })
    }
}
