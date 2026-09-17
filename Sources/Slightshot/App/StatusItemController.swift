import AppKit

/// The menu-bar presence. Slightshot has no Dock icon and no main window, so
/// this menu is the app's only permanent surface.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let onCaptureArea: () -> Void
    private let onSaveFullScreen: () -> Void
    private let onCopyFullScreen: () -> Void

    init(onCaptureArea: @escaping () -> Void,
         onSaveFullScreen: @escaping () -> Void,
         onCopyFullScreen: @escaping () -> Void) {
        self.onCaptureArea = onCaptureArea
        self.onSaveFullScreen = onSaveFullScreen
        self.onCopyFullScreen = onCopyFullScreen
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder",
                                   accessibilityDescription: "Slightshot")
            button.image?.isTemplate = true
            button.toolTip = "Slightshot"
        }

        let menu = NSMenu()
        menu.delegate = self
        // Otherwise AppKit re-enables every item with a valid target/action and
        // "Check for Updates…" appears live even without an update feed.
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let settings = Settings.shared
        menu.removeAllItems()

        menu.addItem(item("Capture Area", settings.captureAreaHotKey, #selector(captureArea)))
        menu.addItem(item("Capture Full Screen", settings.saveFullScreenHotKey, #selector(saveFullScreen)))
        menu.addItem(item("Copy Full Screen", settings.copyFullScreenHotKey, #selector(copyFullScreen)))
        menu.addItem(.separator())

        menu.addItem(item("Open Screenshots Folder", nil, #selector(openFolder)))
        menu.addItem(.separator())

        let settingsItem = item("Settings…", nil, #selector(openSettings))
        settingsItem.keyEquivalent = ","
        settingsItem.keyEquivalentModifierMask = .command
        menu.addItem(settingsItem)

        let updates = item("Check for Updates…", nil, #selector(checkForUpdates))
        updates.isEnabled = UpdaterController.shared.canCheckForUpdates
        menu.addItem(updates)

        menu.addItem(item("About Slightshot", nil, #selector(about)))
        menu.addItem(.separator())

        let quit = item("Quit Slightshot", nil, #selector(quit))
        quit.keyEquivalent = "q"
        quit.keyEquivalentModifierMask = .command
        menu.addItem(quit)
    }

    private func item(_ title: String, _ combo: KeyCombo?, _ action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        if let combo, !combo.isEmpty {
            menuItem.keyEquivalent = KeyCombo.keyName(for: combo.keyCode).lowercased()
            menuItem.keyEquivalentModifierMask = combo.cocoaModifiers
        }
        return menuItem
    }

    // MARK: - Actions

    @objc private func captureArea() { onCaptureArea() }
    @objc private func saveFullScreen() { onSaveFullScreen() }
    @objc private func copyFullScreen() { onCopyFullScreen() }

    @objc private func openFolder() {
        let directory = Settings.shared.saveDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    @objc private func openSettings() { PreferencesWindowController.shared.show() }
    @objc private func checkForUpdates() { UpdaterController.shared.checkForUpdates() }
    @objc private func about() { AboutPanel.show() }
    @objc private func quit() { NSApp.terminate(nil) }
}
