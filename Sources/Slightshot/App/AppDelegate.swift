import AppKit
import UserNotifications

/// Actions Slightshot can be asked to run straight from the command line,
/// which is what makes it scriptable from Shortcuts, Alfred or Raycast:
///
///     open -a Slightshot --args --capture-area
nonisolated enum LaunchCommand: String {
    case captureArea = "--capture-area"
    case saveFullScreen = "--capture-full"
    case copyFullScreen = "--copy-full"

    init?(arguments: [String]) {
        guard let match = arguments.dropFirst().compactMap({ LaunchCommand(rawValue: $0) }).first else { return nil }
        self = match
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private let launchCommand: LaunchCommand?

    init(launchCommand: LaunchCommand?) {
        self.launchCommand = launchCommand
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("Slightshot \(AppInfo.versionString, privacy: .public) launched")

        statusItem = StatusItemController(
            onCaptureArea: { OverlayCoordinator.shared.beginRegionCapture() },
            onSaveFullScreen: { OverlayCoordinator.shared.captureFullScreen(.save) },
            onCopyFullScreen: { OverlayCoordinator.shared.captureFullScreen(.copy) }
        )

        Settings.shared.onHotKeysChanged = { [weak self] in self?.registerHotKeys() }
        registerHotKeys()

        UpdaterController.shared.start()
        requestNotificationAuthorizationIfNeeded()
        checkScreenRecordingPermissionOnFirstRun()

        if let launchCommand { run(launchCommand) }
    }

    private func run(_ command: LaunchCommand) {
        switch command {
        case .captureArea: OverlayCoordinator.shared.beginRegionCapture()
        case .saveFullScreen: OverlayCoordinator.shared.captureFullScreen(.save)
        case .copyFullScreen: OverlayCoordinator.shared.captureFullScreen(.copy)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyCenter.shared.unregisterAll()
    }

    /// No Dock icon, so there is nothing to reopen.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        PreferencesWindowController.shared.show()
        return false
    }

    // MARK: - Hotkeys

    private func registerHotKeys() {
        let settings = Settings.shared
        let failures = HotKeyCenter.shared.reload([
            (settings.captureAreaHotKey, { OverlayCoordinator.shared.beginRegionCapture() }),
            (settings.saveFullScreenHotKey, { OverlayCoordinator.shared.captureFullScreen(.save) }),
            (settings.copyFullScreenHotKey, { OverlayCoordinator.shared.captureFullScreen(.copy) }),
        ])

        guard !failures.isEmpty else { return }
        let list = failures.map(\.displayString).joined(separator: ", ")
        Log.hotkeys.warning("Unavailable shortcuts: \(list, privacy: .public)")
    }

    // MARK: - First run

    private func checkScreenRecordingPermissionOnFirstRun() {
        guard !ScreenRecordingPermission.isGranted else { return }
        // Asking here means the system prompt appears while the user is still
        // thinking about Slightshot, instead of the first time they hit ⌘⇧9.
        ScreenRecordingPermission.request()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard !ScreenRecordingPermission.isGranted else { return }
            ScreenRecordingPermission.presentDeniedAlert()
        }
    }

    private func requestNotificationAuthorizationIfNeeded() {
        guard Settings.shared.showNotification, Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
            if let error {
                Log.app.error("Notification authorisation failed: \(error.localizedDescription, privacy: .public)")
            } else {
                Log.app.debug("Notification authorisation granted: \(granted)")
            }
        }
    }
}

nonisolated enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
    static var versionString: String { "\(version) (\(build))" }
    static let repositoryURL = URL(string: "https://github.com/jmpijll/slightshot")!
}

enum AboutPanel {
    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSAttributedString(
            string: """
            An open-source screenshot tool for macOS, inspired by Lightshot.

            Press \(Settings.shared.captureAreaHotKey.displayString) to capture an area.
            """,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            .applicationVersion: AppInfo.version,
            .version: AppInfo.build,
        ])
    }
}
