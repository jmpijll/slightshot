import SwiftUI
import AppKit

struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            ShortcutsTab()
                .tabItem { Label("Shortcuts", systemImage: "command") }
            OutputTab()
                .tabItem { Label("Output", systemImage: "square.and.arrow.down") }
            AppearanceTab()
                .tabItem { Label("Capture", systemImage: "viewfinder") }
        }
        .padding(.top, 8)
        .frame(width: 540, height: 580)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @Bindable private var settings = Settings.shared
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var notificationsDenied = false
    @State private var requestingNotifications = false

    var body: some View {
        Form {
            Section {
                Toggle("Launch Slightshot at login", isOn: $launchAtLogin)
                    .disabled(!LaunchAtLogin.isAvailable)
                    .onChange(of: launchAtLogin) { _, newValue in LaunchAtLogin.set(newValue) }

                Toggle("Play a shutter sound", isOn: $settings.playSound)
                Toggle("Show a notification after saving", isOn: $settings.showNotification)
                    .onChange(of: settings.showNotification) { _, isOn in
                        Task {
                            guard isOn else { notificationsDenied = false; return }
                            requestingNotifications = true
                            notificationsDenied = !(await SaveNotification.requestAuthorization())
                            requestingNotifications = false
                        }
                    }
                if settings.showNotification && notificationsDenied {
                    LabeledContent {
                        Button("Open System Settings…") { NSWorkspace.shared.open(SaveNotification.settingsURL) }
                    } label: {
                        Text("Notifications are turned off for Slightshot in System Settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .task { await refreshNotificationsDenied() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await refreshNotificationsDenied() }
            }

            Section {
                Picker("Return key action", selection: $settings.defaultAction) {
                    ForEach(DefaultAction.allCases) { action in
                        Text(action.displayName).tag(action)
                    }
                }
            } footer: {
                Text("Double-click inside the selection to use this action.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Screen Recording") {
                    HStack(spacing: 8) {
                        Image(nsImage: (ScreenRecordingPermission.isGranted ? ProductIcon.check : .warning)
                            .image(accessibilityDescription: ScreenRecordingPermission.isGranted
                                   ? "Screen recording granted" : "Screen recording not granted"))
                            .foregroundStyle(ScreenRecordingPermission.isGranted ? .green : .orange)
                        Text(ScreenRecordingPermission.isGranted ? "Granted" : "Not granted")
                        if !ScreenRecordingPermission.isGranted {
                            Button("Open Settings…") { ScreenRecordingPermission.presentDeniedAlert() }
                        }
                    }
                }
            } footer: {
                Text("macOS requires this permission for any app that captures the screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Version") { Text(AppInfo.versionString).monospacedDigit() }
                HStack {
                    Button("Check for Updates…") { UpdaterController.shared.checkForUpdates() }
                        .disabled(!UpdaterController.shared.canCheckForUpdates)
                    Spacer()
                    Link("Source on GitHub", destination: AppInfo.repositoryURL)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Catches a change made on the linked System Settings page once the user comes back.
    private func refreshNotificationsDenied() async {
        // macOS reports a prompt that is still on screen as denied; the request gives the real answer.
        guard settings.showNotification, !requestingNotifications else { return }
        notificationsDenied = await SaveNotification.isDenied()
    }
}

// MARK: - Shortcuts

private struct ShortcutsTab: View {
    @Bindable private var settings = Settings.shared
    private let hotKeys = HotKeyCenter.shared
    @State private var rejections: [HotKeyAction: String] = [:]

    var body: some View {
        Form {
            Section {
                ForEach(HotKeyAction.allCases, id: \.self) { action in
                    LabeledContent(action.title) {
                        ShortcutRecorder(combo: settings[keyPath: action.setting],
                                         onRecord: { record($0, for: action) },
                                         onClear: { clear(action) })
                    }
                    if let warning = warning(for: action) {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Global shortcuts")
            } footer: {
                Text("Click a field, then press the combination. Escape clears it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("While capturing") {
                ForEach(Self.overlayShortcuts, id: \.0) { shortcut, description in
                    LabeledContent(description) {
                        Text(shortcut)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func record(_ combo: KeyCombo, for action: HotKeyAction) -> Bool {
        let assigned = Dictionary(uniqueKeysWithValues: HotKeyAction.allCases.map {
            ($0, settings[keyPath: $0.setting])
        })
        if let rejection = hotKeys.rejection(for: combo, action: action, assigned: assigned) {
            rejections[action] = "\(action.title): \(rejection.message(for: combo))"
            return false
        }
        rejections[action] = nil
        settings[keyPath: action.setting] = combo
        return true
    }

    private func clear(_ action: HotKeyAction) {
        rejections[action] = nil
        settings[keyPath: action.setting] = .none
    }

    private func warning(for action: HotKeyAction) -> String? {
        if let rejection = rejections[action] { return rejection }
        guard hotKeys.unavailable.contains(action) else { return nil }
        let combo = settings[keyPath: action.setting]
        return "\(action.title): \(ShortcutRejection.unavailable.message(for: combo)) Choose another shortcut."
    }

    private static let overlayShortcuts: [(String, String)] = [
        ("⌘A", "Select the whole screen"),
        ("⌘C", "Copy to clipboard"),
        ("⌘S", "Save to file"),
        ("⇧⌘S", "Save as…"),
        ("⌘P", "Print"),
        ("⌘Z", "Undo the last annotation"),
        ("⌘⇧Z", "Redo the last undone annotation"),
        ("↩", "Confirm"),
        ("⎋", "Cancel"),
        ("⇧drag", "Constrain to a square or 45°"),
        ("⌘drag", "Select and copy in one motion"),
        ("↑↓←→", "Nudge the selection by one pixel"),
    ]
}

private extension HotKeyAction {
    var setting: ReferenceWritableKeyPath<Settings, KeyCombo> {
        switch self {
        case .captureArea: \.captureAreaHotKey
        case .saveFullScreen: \.saveFullScreenHotKey
        case .copyFullScreen: \.copyFullScreenHotKey
        }
    }
}

// MARK: - Output

private struct OutputTab: View {
    @Bindable private var settings = Settings.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Save to") {
                    HStack {
                        Text(settings.saveDirectory.path)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseDirectory)
                    }
                }
                TextField("File name", text: $settings.filenameTemplate)
            } header: {
                Text("Files")
            } footer: {
                Text("Tokens: {date} {time} {timestamp} {width} {height}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Format", selection: $settings.imageFormat) {
                    ForEach(ImageFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                if settings.imageFormat == .jpeg {
                    LabeledContent("Quality") {
                        Slider(value: $settings.jpegQuality, in: 0.3...1.0) {
                            Text("Quality")
                        } minimumValueLabel: {
                            Text("30%").font(.caption)
                        } maximumValueLabel: {
                            Text("100%").font(.caption)
                        }
                        .frame(width: 220)
                    }
                }
                Toggle("Also copy to the clipboard when saving", isOn: $settings.copyAfterSave)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveDirectory
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.saveDirectory = url
    }
}

// MARK: - Capture appearance

private struct AppearanceTab: View {
    @Bindable private var settings = Settings.shared

    var body: some View {
        Form {
            Section("Overlay") {
                Toggle("Show the pixel magnifier", isOn: $settings.showMagnifier)
                Toggle("Show selection dimensions", isOn: $settings.showDimensions)
                LabeledContent("Dim the rest of the screen") {
                    Slider(value: $settings.dimOpacity, in: 0...0.85) {
                        Text("Dimming")
                    } minimumValueLabel: {
                        Text("Off").font(.caption)
                    } maximumValueLabel: {
                        Text("Dark").font(.caption)
                    }
                    .frame(width: 220)
                }
            }

            Section("Capture") {
                Toggle("Capture at full Retina resolution", isOn: $settings.retinaScale)
                Toggle("Include the mouse pointer", isOn: $settings.captureCursor)
            }

            Section("Annotations") {
                Toggle("Remember the last tool used", isOn: $settings.rememberLastTool)
                LabeledContent("Line thickness") {
                    Slider(value: $settings.lineWidth, in: 1...12, step: 1)
                        .frame(width: 220)
                }
                LabeledContent("Text size") {
                    Slider(value: $settings.fontSize, in: 10...48, step: 1)
                        .frame(width: 220)
                }
            }
        }
        .formStyle(.grouped)
    }
}
