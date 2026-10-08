import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private let launchCommand: LaunchCommand?
    private let inbox: ApplicationCommandInbox
    private var hasFinishedLaunching = false
    private var receivedURLs = false
    private lazy var commandDispatcher = ApplicationCommandDispatcher(
        isBusy: { OverlayCoordinator.shared.isBusy || RecordingCoordinator.shared.isBusy },
        capture: Self.capture,
        reopen: { PreferencesWindowController.shared.show() }
    )

    init(launchCommand: LaunchCommand?, inbox: ApplicationCommandInbox) {
        self.launchCommand = launchCommand
        self.inbox = inbox
        super.init()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        receivedURLs = true
        for command in urls.compactMap(LaunchCommand.init(url:)) { route(.capture(command)) }
        if !inbox.isOwner, hasFinishedLaunching { application.terminate(nil) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ownership is claimed atomically in main, before AppKit startup.
        // A duplicate never creates a menu item, hotkey, updater or capture session.
        guard inbox.isOwner else {
            hasFinishedLaunching = true
            if let launchCommand { route(.capture(launchCommand)) }
            finishDuplicateLaunch(notification)
            return
        }
        Log.app.info("Slightshot \(AppInfo.versionString, privacy: .public) launched")

        statusItem = StatusItemController(
            onCaptureArea: { [weak self] in self?.route(.capture(.captureArea)) },
            onSaveFullScreen: { [weak self] in self?.route(.capture(.saveFullScreen)) },
            onCopyFullScreen: { [weak self] in self?.route(.capture(.copyFullScreen)) }
        )

        Settings.shared.onHotKeysChanged = { [weak self] in self?.registerHotKeys() }
        registerHotKeys()

        UpdaterController.shared.start()
        requestNotificationAuthorizationIfNeeded()
        checkScreenRecordingPermissionOnFirstRun()

        hasFinishedLaunching = true
        do {
            try inbox.startReceiving { [weak self] in self?.commandDispatcher.run($0) }
        } catch {
            Log.app.error("Command routing could not start: \(error.localizedDescription, privacy: .public)")
            NSApp.terminate(nil)
            return
        }
        if let launchCommand { route(.capture(launchCommand)) }
    }

    private static func capture(_ command: LaunchCommand) {
        switch command {
        case .captureArea: OverlayCoordinator.shared.beginRegionCapture()
        case .saveFullScreen: OverlayCoordinator.shared.captureFullScreen(.save)
        case .copyFullScreen: OverlayCoordinator.shared.captureFullScreen(.copy)
        }
    }

    private func route(_ command: ApplicationCommand) {
        if inbox.isOwner, hasFinishedLaunching {
            commandDispatcher.run(command)
            return
        }
        do {
            try inbox.send(command)
        } catch {
            Log.app.error("Command could not be forwarded: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func finishDuplicateLaunch(_ notification: Notification) {
        let isDefaultLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        if isDefaultLaunch || launchCommand != nil || receivedURLs {
            DispatchQueue.main.async { [self] in
                if launchCommand == nil, !receivedURLs { route(.reopen) }
                NSApp.terminate(nil)
            }
        } else {
            // For a URL launch, AppKit may deliver openURLs after didFinishLaunching.
            // The URL callback forwards it and exits. Bound the wait if no event arrives.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { NSApp.terminate(nil) }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard inbox.isOwner else { return .terminateNow }
        guard RecordingCoordinator.shared.isBusy else { return .terminateNow }
        Task {
            await RecordingCoordinator.shared.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        inbox.stopReceiving()
        guard inbox.isOwner else { return }
        HotKeyCenter.shared.unregisterAll()
    }

    /// No Dock icon, so there is nothing to reopen.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        route(.reopen)
        return false
    }

    // MARK: - Hotkeys

    private func registerHotKeys() {
        let settings = Settings.shared
        let failures = HotKeyCenter.shared.reload([
            (settings.captureAreaHotKey, { [weak self] in self?.route(.capture(.captureArea)) }),
            (settings.saveFullScreenHotKey, { [weak self] in self?.route(.capture(.saveFullScreen)) }),
            (settings.copyFullScreenHotKey, { [weak self] in self?.route(.capture(.copyFullScreen)) }),
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
