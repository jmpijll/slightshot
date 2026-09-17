import AppKit
import Observation

nonisolated enum ImageFormat: String, CaseIterable, Identifiable, Sendable {
    case png, jpeg, tiff
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .tiff: "TIFF"
        }
    }
    var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .tiff: "tiff"
        }
    }
}

/// What happens the moment a selection is confirmed with Return / double-click.
nonisolated enum DefaultAction: String, CaseIterable, Identifiable, Sendable {
    case copy, save, stayOpen
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .copy: "Copy to clipboard"
        case .save: "Save to file"
        case .stayOpen: "Do nothing (keep editing)"
        }
    }
}

/// User preferences, persisted in `UserDefaults` and observable by SwiftUI.
@Observable
final class Settings {
    static let shared = Settings()

    @ObservationIgnored private let defaults: UserDefaults
    /// Fired whenever a hotkey changes so `HotKeyCenter` can re-register.
    @ObservationIgnored var onHotKeysChanged: (() -> Void)?

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.captureArea: KeyCombo.captureArea.storageValue,
            Key.saveFullScreen: KeyCombo.saveFullScreen.storageValue,
            Key.copyFullScreen: KeyCombo.copyFullScreen.storageValue,
            Key.imageFormat: ImageFormat.png.rawValue,
            Key.jpegQuality: 0.9,
            Key.filenameTemplate: "Screenshot {date} at {time}",
            Key.copyAfterSave: false,
            Key.showMagnifier: true,
            Key.showDimensions: true,
            Key.dimOpacity: 0.45,
            Key.annotationColorHex: "#FF3B30",
            Key.lineWidth: 3.0,
            Key.fontSize: 18.0,
            Key.rememberLastTool: true,
            Key.playSound: true,
            Key.showNotification: false,
            Key.defaultAction: DefaultAction.copy.rawValue,
            Key.captureCursor: false,
            Key.retinaScale: true,
        ])
    }

    private enum Key {
        static let captureArea = "hotkey.captureArea"
        static let saveFullScreen = "hotkey.saveFullScreen"
        static let copyFullScreen = "hotkey.copyFullScreen"
        static let imageFormat = "output.format"
        static let jpegQuality = "output.jpegQuality"
        static let saveDirectory = "output.saveDirectory"
        static let filenameTemplate = "output.filenameTemplate"
        static let copyAfterSave = "output.copyAfterSave"
        static let showMagnifier = "overlay.showMagnifier"
        static let showDimensions = "overlay.showDimensions"
        static let dimOpacity = "overlay.dimOpacity"
        static let annotationColorHex = "editor.colorHex"
        static let lineWidth = "editor.lineWidth"
        static let fontSize = "editor.fontSize"
        static let rememberLastTool = "editor.rememberLastTool"
        static let playSound = "feedback.playSound"
        static let showNotification = "feedback.showNotification"
        static let defaultAction = "overlay.defaultAction"
        static let captureCursor = "capture.includeCursor"
        static let retinaScale = "capture.retinaScale"
    }

    // MARK: - Hotkeys

    var captureAreaHotKey: KeyCombo {
        get { combo(Key.captureArea, fallback: .captureArea) }
        set { setCombo(newValue, Key.captureArea) }
    }
    var saveFullScreenHotKey: KeyCombo {
        get { combo(Key.saveFullScreen, fallback: .saveFullScreen) }
        set { setCombo(newValue, Key.saveFullScreen) }
    }
    var copyFullScreenHotKey: KeyCombo {
        get { combo(Key.copyFullScreen, fallback: .copyFullScreen) }
        set { setCombo(newValue, Key.copyFullScreen) }
    }

    private func combo(_ key: String, fallback: KeyCombo) -> KeyCombo {
        access(keyPath: \.hotKeyRevision)
        guard let raw = defaults.string(forKey: key) else { return fallback }
        return KeyCombo(storageValue: raw) ?? fallback
    }

    private func setCombo(_ value: KeyCombo, _ key: String) {
        withMutation(keyPath: \.hotKeyRevision) {
            defaults.set(value.storageValue, forKey: key)
            hotKeyRevisionStorage &+= 1
        }
        onHotKeysChanged?()
    }

    /// Bumped on every hotkey mutation so observers re-read all three combos.
    @ObservationIgnored private var hotKeyRevisionStorage: UInt64 = 0
    var hotKeyRevision: UInt64 { hotKeyRevisionStorage }

    // MARK: - Output

    var imageFormat: ImageFormat {
        get { ImageFormat(rawValue: string(Key.imageFormat)) ?? .png }
        set { set(newValue.rawValue, Key.imageFormat) }
    }
    var jpegQuality: Double {
        get { double(Key.jpegQuality) }
        set { set(newValue, Key.jpegQuality) }
    }
    var filenameTemplate: String {
        get { string(Key.filenameTemplate) }
        set { set(newValue, Key.filenameTemplate) }
    }
    var copyAfterSave: Bool {
        get { bool(Key.copyAfterSave) }
        set { set(newValue, Key.copyAfterSave) }
    }

    /// Where `Save` writes without prompting. Defaults to ~/Pictures/Screenshots.
    var saveDirectory: URL {
        get {
            access(keyPath: \.saveDirectory)
            if let path = defaults.string(forKey: Key.saveDirectory), !path.isEmpty {
                return URL(fileURLWithPath: path)
            }
            return Self.defaultSaveDirectory
        }
        set {
            withMutation(keyPath: \.saveDirectory) {
                defaults.set(newValue.path, forKey: Key.saveDirectory)
            }
        }
    }

    static var defaultSaveDirectory: URL {
        let pictures = FileManager.default
            .urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return pictures.appendingPathComponent("Screenshots", isDirectory: true)
    }

    // MARK: - Overlay & editor

    var showMagnifier: Bool {
        get { bool(Key.showMagnifier) }
        set { set(newValue, Key.showMagnifier) }
    }
    var showDimensions: Bool {
        get { bool(Key.showDimensions) }
        set { set(newValue, Key.showDimensions) }
    }
    var dimOpacity: Double {
        get { double(Key.dimOpacity) }
        set { set(newValue, Key.dimOpacity) }
    }
    var annotationColor: NSColor {
        get { NSColor(hex: string(Key.annotationColorHex)) ?? .systemRed }
        set { set(newValue.hexString, Key.annotationColorHex) }
    }
    var lineWidth: Double {
        get { double(Key.lineWidth) }
        set { set(newValue, Key.lineWidth) }
    }
    var fontSize: Double {
        get { double(Key.fontSize) }
        set { set(newValue, Key.fontSize) }
    }
    var rememberLastTool: Bool {
        get { bool(Key.rememberLastTool) }
        set { set(newValue, Key.rememberLastTool) }
    }
    var defaultAction: DefaultAction {
        get { DefaultAction(rawValue: string(Key.defaultAction)) ?? .copy }
        set { set(newValue.rawValue, Key.defaultAction) }
    }

    // MARK: - Capture & feedback

    var captureCursor: Bool {
        get { bool(Key.captureCursor) }
        set { set(newValue, Key.captureCursor) }
    }
    var retinaScale: Bool {
        get { bool(Key.retinaScale) }
        set { set(newValue, Key.retinaScale) }
    }
    var playSound: Bool {
        get { bool(Key.playSound) }
        set { set(newValue, Key.playSound) }
    }
    var showNotification: Bool {
        get { bool(Key.showNotification) }
        set { set(newValue, Key.showNotification) }
    }

    // MARK: - Typed accessors

    private func string(_ key: String) -> String {
        access(keyPath: \.revision)
        return defaults.string(forKey: key) ?? ""
    }
    private func bool(_ key: String) -> Bool {
        access(keyPath: \.revision)
        return defaults.bool(forKey: key)
    }
    private func double(_ key: String) -> Double {
        access(keyPath: \.revision)
        return defaults.double(forKey: key)
    }
    private func set(_ value: Any, _ key: String) {
        withMutation(keyPath: \.revision) {
            defaults.set(value, forKey: key)
            revisionStorage &+= 1
        }
    }

    @ObservationIgnored private var revisionStorage: UInt64 = 0
    var revision: UInt64 { revisionStorage }
}
