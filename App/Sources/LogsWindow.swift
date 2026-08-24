import SwiftUI
import AppKit
import HomePortKit

/// One logs window per machine; reopening brings the existing one forward.
@MainActor
enum LogsWindow {
    private static var windows: [String: NSWindow] = [:]

    static func open(for machine: Machine, model: FleetModel) {
        if let window = windows[machine.name] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = String(localized: "Logs — \(machine.name)")
        // See ControlCenterWindow: a raw NSHostingView would draw under the title bar.
        window.contentViewController = NSHostingController(
            rootView: LogsView(machine: machine, model: model))
        // Same as the control center: Theme is a light palette, the frame must agree.
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        window.center()
        windows[machine.name] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct LogsView: View {
    let machine: Machine
    let model: FleetModel
    @State private var text = String(localized: "Loading…")
    @State private var loading = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(text)
                    .styled(Theme.data)
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            Divider()
            HStack {
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button { load() } label: { Text("Refresh") }.disabled(loading)
            }
            .padding(8)
        }
        .onAppear { load() }
    }

    private func load() {
        loading = true
        Task {
            text = await model.fetchLogs(for: machine)
            loading = false
        }
    }
}
