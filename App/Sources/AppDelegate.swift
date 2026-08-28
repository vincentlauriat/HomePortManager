import AppKit
import HomePortKit

/// Now that the app also shows in the Dock, clicking its icon has to do something — AppKit
/// calls this when there is no visible window to simply refocus. `model` is wired in
/// `HomePortMenuApp.init()`, right after the `FleetModel` it shares with the menu bar exists.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: FleetModel?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows, let model else { return true }
        ControlCenterWindow.open(model: model)
        return false
    }
}
