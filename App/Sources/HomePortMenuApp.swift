import SwiftUI
import HomePortKit

@main
struct HomePortMenuApp: App {
    @StateObject private var model = FleetModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        appDelegate.model = model
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.health.symbolName)
        }
        .menuBarExtraStyle(.window)
    }
}

extension FleetHealth {
    var symbolName: String {
        switch self {
        case .allGreen: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle.fill"
        case .unknown: return "circle.dotted"
        }
    }
}
