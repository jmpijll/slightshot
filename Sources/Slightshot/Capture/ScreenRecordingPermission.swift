import AppKit
import CoreGraphics

/// Screen Recording is the one permission Slightshot cannot work without.
enum ScreenRecordingPermission {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Triggers the system prompt. Returns `true` if access is already granted;
    /// the first call on a fresh install always returns `false` because macOS
    /// only grants the permission after the app is relaunched.
    @discardableResult
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Explains the situation and offers to open the right Settings pane.
    static func presentDeniedAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Slightshot needs Screen Recording permission"
        alert.informativeText = """
        macOS requires this permission for any app that captures the screen.

        Open System Settings › Privacy & Security › Screen & System Audio \
        Recording and switch Slightshot on, then relaunch the app.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}
