import AppKit
import Sparkle

/// Thin wrapper around Sparkle so the rest of the app never imports it.
final class UpdaterController: NSObject, SPUUpdaterDelegate {
    static let shared = UpdaterController()

    private var controller: SPUStandardUpdaterController?

    /// Sparkle needs a real bundle with `SUFeedURL`; in a bare `swift run` build
    /// there is none, so updating is simply disabled rather than crashing.
    func start() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            Log.updater.notice("No SUFeedURL in Info.plist — automatic updates disabled")
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: self,
                                                  userDriverDelegate: nil)
    }

    var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates ?? false }

    func checkForUpdates() {
        guard let controller else {
            OutputService.presentError("This build of Slightshot has no update feed configured.")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }
}
