import Foundation
import UserNotifications
import HomePortKit

/// State-transition and action-outcome notifications — never repeated nagging. Story 2.2b
/// adds a critical-event notification and the click that routes it to the machine's Events
/// tab; the rest of this file is unchanged from 1.x/2.2a (no defect found against it across
/// two review passes of this story).
enum Notifier {
    /// Set once by `FleetModel.init` at launch, read by the click delegate below. Written
    /// and read only from the main actor: `FleetModel` is itself `@MainActor`, and the
    /// delegate hops onto it before touching this.
    @MainActor static weak var model: FleetModel?

    /// Held here so `UNUserNotificationCenter` does not outlive its only strong reference —
    /// its own `delegate` property does not retain.
    private static let delegate = ClickDelegate()

    static func requestPermission() {
        UNUserNotificationCenter.current().delegate = delegate
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// `machine`, when given, rides `userInfo` so a click on this notification can route
    /// back to that machine's fiche (`ClickDelegate` below).
    static func notify(title: String, body: String, machine: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let machine { content.userInfo = ["machine": machine] }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// A critical event's notification (story 2.2b, UX-DR9): title and body both go
    /// through `String(localized:)`, and `kind`/`subject`/`detail` — machine content — are
    /// carried through untouched inside them, on the same template pattern as
    /// `FleetModel.swift:408,417`. Never the machine content alone in the title: a raw
    /// `event.subject` there would be indistinguishable from the app's own words.
    static func notifyCriticalEvent(machine: String, event: HomeportEvent) {
        let title = String(localized: "\(machine): critical event")
        let body = String(localized: "\(event.subject) — \(event.kind) — \(event.detail ?? "—")")
        notify(title: title, body: body, machine: machine)
    }

    /// Routes a clicked critical-event notification to its machine's Events tab, reusing
    /// `ControlCenterWindow.open`/`navigate(to:tab:)` and the `ControlCenterCommands`
    /// bus — no defect found against this mechanism across two review passes of this story.
    private final class ClickDelegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter,
                                    didReceive response: UNNotificationResponse,
                                    withCompletionHandler completionHandler: @escaping () -> Void) {
            guard let machine = response.notification.request.content.userInfo["machine"] as? String else {
                completionHandler()
                return
            }
            Task { @MainActor in
                // Tolerates a click landing before `FleetModel.init` finished setting
                // `Notifier.model` (a race with app launch) — traced rather than dropped
                // silently, same channel as every other degraded-but-not-fatal path.
                guard let model = Notifier.model else {
                    FileHandle.standardError.write(Data(
                        "warning: notification click for '\(machine)' arrived before the app model was ready\n".utf8))
                    completionHandler()
                    return
                }
                ControlCenterWindow.open(model: model)
                ControlCenterWindow.navigate(to: machine, tab: .events)
                completionHandler()
            }
        }
    }
}
