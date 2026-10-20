import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private let launchCommand: LaunchCommand?
    private let inbox: ApplicationCommandInbox
    private var hasFinishedLaunching = false
    private var receivedURLs = false
    private var countdownPanel: DelayedCapturePanel?
    private lazy var delayedCapture = DelayedCaptureController(
        isBusy: { OverlayCoordinator.shared.isBusy || RecordingCoordinator.shared.isBusy },
        show: { [weak self] seconds in self?.showCountdown(seconds) },
        hide: { [weak self] in self?.countdownPanel?.close(); self?.countdownPanel = nil },
        capture: { OverlayCoordinator.shared.beginRegionCapture() }
    )
    private lazy var commandDispatcher = ApplicationCommandDispatcher(
        isBusy: { OverlayCoordinator.shared.isBusy || RecordingCoordinator.shared.isBusy },
        capture: { [weak self] command in self?.delayedCapture.cancel(); Self.capture(command) },
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
        removeAbandonedRecordings()

        statusItem = StatusItemController(
            onCaptureArea: { [weak self] in self?.route(.capture(.captureArea)) },
            onSaveFullScreen: { [weak self] in self?.route(.capture(.saveFullScreen)) },
            onCopyFullScreen: { [weak self] in self?.route(.capture(.copyFullScreen)) },
            onDelayedCapture: { [weak self] in self?.delayedCapture.start() },
            onEditClipboard: { [weak self] in
                self?.delayedCapture.cancel()
                OverlayCoordinator.shared.editImageFromClipboard()
            }
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

    private func showCountdown(_ seconds: Int) {
        if countdownPanel == nil {
            countdownPanel = DelayedCapturePanel { [weak self] in self?.delayedCapture.cancel() }
            countdownPanel?.orderFrontRegardless()
        }
        countdownPanel?.update(seconds: seconds)
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
        delayedCapture.cancel()
        return QuitGuard.shared.reply()
    }

    func applicationWillTerminate(_ notification: Notification) {
        inbox.stopReceiving()
        guard inbox.isOwner else { return }
        delayedCapture.cancel()
        HotKeyCenter.shared.unregisterAll()
    }

    /// No Dock icon, so there is nothing to reopen.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        route(.reopen)
        return false
    }

    private func removeAbandonedRecordings() {
        let launched = NSRunningApplication.current.launchDate ?? Date()
        let stagingParents = Set(RecordingExport.stagingParents + [Settings.shared.saveDirectory])
        Task.detached(priority: .utility) {
            ScreenRecordingSession.removeAbandonedDirectories(
                prefix: ScreenRecordingSession.directoryPrefix, in: FileManager.default.temporaryDirectory,
                createdBefore: launched)
            for parent in stagingParents {
                ScreenRecordingSession.removeAbandonedDirectories(
                    prefix: RecordingExport.stagingPrefix, in: parent, createdBefore: launched)
                RecordingExport.forgetStagingParent(parent)
            }
        }
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

/// AppKit quits at once when `terminate` arrives while the delegate's prompt is
/// open, without asking the delegate again, so repeated requests stop here.
final class SlightshotApplication: NSApplication {
    override func terminate(_ sender: Any?) {
        guard !QuitGuard.shared.isPending else { return }
        super.terminate(sender)
    }
}

/// Work that exists only in memory or a temporary folder, so quitting would lose it.
enum UnsavedWork: Equatable {
    case recording(canSave: Bool)
    case annotations
}

enum QuitChoice { case save, copy, discard, cancel }

/// Decides whether a quit, logout or update relaunch may proceed. It never
/// returns `.terminateLater`: AppKit quits on a second request while a reply is
/// pending, and a reply that needs the main queue never arrives when `terminate`
/// was called from a main-queue block. Save cancels the quit and quits again
/// once the recording is written.
final class QuitGuard {
    private let unsavedWork: () -> UnsavedWork?
    private let ask: (UnsavedWork) -> QuitChoice
    private let saveRecording: () async -> Bool
    private let copyAnnotations: () -> Bool
    private let discardRecording: () -> Void
    private let quit: () -> Void
    /// A prompt or a save started from a quit is in progress.
    private(set) var isPending = false

    init(unsavedWork: @escaping () -> UnsavedWork?, ask: @escaping (UnsavedWork) -> QuitChoice,
         saveRecording: @escaping () async -> Bool, copyAnnotations: @escaping () -> Bool,
         discardRecording: @escaping () -> Void, quit: @escaping () -> Void = { NSApp.terminate(nil) }) {
        self.unsavedWork = unsavedWork
        self.ask = ask
        self.saveRecording = saveRecording
        self.copyAnnotations = copyAnnotations
        self.discardRecording = discardRecording
        self.quit = quit
    }

    /// Replaced only by the headless `--quit-guard-probe`.
    static var shared = QuitGuard(
        unsavedWork: { RecordingCoordinator.shared.unsavedWork ?? OverlayCoordinator.shared.unsavedWork },
        ask: { work in OverlayCoordinator.shared.withOverlayHidden { ask(about: work) } },
        saveRecording: { await RecordingCoordinator.shared.saveBeforeQuitting() },
        copyAnnotations: { OverlayCoordinator.shared.copyAnnotatedCapture() },
        discardRecording: { RecordingCoordinator.shared.discardForTermination() }
    )

    func reply() -> NSApplication.TerminateReply {
        // A quit Apple event (logout) consults the delegate even while a prompt is open.
        guard !isPending else { return .terminateCancel }
        guard let work = unsavedWork() else { return .terminateNow }
        isPending = true
        let choice = ask(work)
        isPending = false
        switch (work, choice) {
        case (_, .cancel):
            return .terminateCancel
        case (.annotations, .copy):
            return copyAnnotations() ? .terminateNow : .terminateCancel
        case (.annotations, _):
            return .terminateNow
        case (.recording(canSave: true), .save):
            isPending = true
            Task {
                let saved = await saveRecording()
                isPending = false
                if saved { quit() }
            }
            return .terminateCancel
        case (.recording, _):
            discardRecording()
            return .terminateNow
        }
    }

    static func ask(about work: UnsavedWork) -> QuitChoice {
        let alert = NSAlert()
        let choices: [QuitChoice]
        switch work {
        case .recording(canSave: true):
            alert.messageText = "Save the recording before quitting?"
            alert.informativeText = "If you don't save it, the recording and its annotations are deleted."
            alert.addButton(withTitle: "Save…")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Discard Recording").hasDestructiveAction = true
            choices = [.save, .cancel, .discard]
        case .recording(canSave: false):
            alert.messageText = "Quit and discard the current recording?"
            alert.informativeText = "Slightshot is still recording or saving. Quitting now deletes the recording."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Discard Recording").hasDestructiveAction = true
            choices = [.cancel, .discard]
        case .annotations:
            alert.messageText = "Copy your annotated capture before quitting?"
            alert.informativeText = "Your annotations haven't been copied or saved. If you discard them, they are lost."
            alert.addButton(withTitle: "Copy")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Discard Annotations").hasDestructiveAction = true
            choices = [.copy, .cancel, .discard]
        }
        NSApp.activate(ignoringOtherApps: true)
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return choices.indices.contains(index) ? choices[index] : .cancel
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
            An open-source screenshot and screen recording app for macOS.

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
