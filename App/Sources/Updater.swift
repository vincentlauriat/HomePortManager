import Sparkle

/// Owns the Sparkle updater for the app's lifetime. `SPUStandardUpdaterController` starts
/// its own background scheduler on init (`startingUpdater: true`) — one instance, created
/// once, is the whole contract; a second would race the first for the same feed.
final class UpdaterViewModel: ObservableObject {
    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
