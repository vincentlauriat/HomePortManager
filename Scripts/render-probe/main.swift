import SwiftUI
import AppKit
import HomePortKit

// Monte les DEUX vraies rangees — memes styles, meme composant — a une largeur donnee,
// se capture, et se termine. Le but est de voir ce qu'un utilisateur verrait.

struct Tab: Identifiable, Hashable {
    let id: Int
    let title: String
}

let tabs = ["Résumé", "Tableau de bord", "Logs", "Événements", "Métriques",
            "Sauvegardes", "Shell", "Mises à jour"].enumerated().map { Tab(id: $0.offset + 1, title: $0.element) }
let actions = ["Sauvegarde", "Redémarrage…", "Diagnostic", "Config",
               "Mise à jour…", "Restauration…", "Désinstallation…"].enumerated().map { Tab(id: $0.offset + 100, title: $0.element) }

struct Probe: View {
    @State var selected: Int = 8   // "Mises a jour" : le dernier, donc replie a coup sur

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: "Barre d'onglets — sélection = \(selected)")
            OverflowRow(
                items: tabs,
                isActive: { $0.id == selected },
                menuTitle: { Text(verbatim: $0.title) },
                activate: { selected = $0.id },
                overflowStyle: { TabPillStyle(selected: $0) },
                itemLabel: { t in
                    Button { selected = t.id } label: { Text(verbatim: t.title) }
                        .buttonStyle(TabPillStyle(selected: t.id == selected))
                })
            Text(verbatim: "Barre d'actions")
            OverflowRow(
                items: actions,
                isActive: { _ in false },
                menuTitle: { Text(verbatim: $0.title) },
                activate: { _ in },
                overflowStyle: { _ in PillButtonStyle(kind: .secondary) },
                itemLabel: { a in
                    Button {} label: { Text(verbatim: a.title) }
                        .buttonStyle(PillButtonStyle(kind: a.title.hasSuffix("…") && a.title != "Redémarrage…" ? .destructive : .secondary))
                })
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.canvas)
    }
}

let width = Double(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "1040") ?? 1040
let outPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/tmp/probe.png"

let app = NSApplication.shared
app.setActivationPolicy(.regular)
// La colonne de detail vaut la largeur de fenetre moins la sidebar (~200pt).
let win = NSWindow(contentRect: NSRect(x: 40, y: 40, width: width - 200, height: 220),
                   styleMask: [.titled], backing: .buffered, defer: false)
win.contentViewController = NSHostingController(rootView: Probe())
win.setContentSize(NSSize(width: width - 200, height: 220))
win.appearance = NSAppearance(named: .aqua)
win.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
    let num = win.windowNumber
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-o", "-x", "-l\(num)", outPath]
    try? p.run()
    p.waitUntilExit()
    print("capture -> \(outPath) (largeur fenetre \(width - 200))")
    app.terminate(nil)
}
app.run()
