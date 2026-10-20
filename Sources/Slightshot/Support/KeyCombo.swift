import AppKit
import Carbon.HIToolbox

/// A global hotkey: a virtual key code plus Carbon modifier flags.
///
/// Stored in `UserDefaults` as a plain `"keyCode:modifiers"` string so that
/// preferences remain human-readable and forward compatible.
nonisolated struct KeyCombo: Equatable, Hashable, Sendable {
    var keyCode: UInt32
    /// Carbon modifier mask (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`).
    var carbonModifiers: UInt32

    static let captureArea = KeyCombo(keyCode: UInt32(kVK_ANSI_9), carbonModifiers: UInt32(cmdKey | shiftKey))
    static let saveFullScreen = KeyCombo(keyCode: UInt32(kVK_ANSI_8), carbonModifiers: UInt32(cmdKey | shiftKey))
    static let copyFullScreen = KeyCombo(keyCode: UInt32(kVK_ANSI_7), carbonModifiers: UInt32(cmdKey | shiftKey))

    var isEmpty: Bool { keyCode == 0 && carbonModifiers == 0 }
    static let none = KeyCombo(keyCode: 0, carbonModifiers: 0)

    // MARK: - Cocoa bridging

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    init(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        self.keyCode = UInt32(event.keyCode)
        self.carbonModifiers = carbon
    }

    /// A global shortcut takes its key from every app, so a key that types
    /// text needs ⌘ or ⌃. Shift and Option alone still type characters
    /// (⇧A, ⌥E). Function keys type nothing and may stand alone.
    var interceptsTyping: Bool {
        Self.functionKeys[Int(keyCode)] == nil && carbonModifiers & UInt32(cmdKey | controlKey) == 0
    }

    var cocoaModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        return flags
    }

    // MARK: - Display

    var displayString: String {
        guard !isEmpty else { return "None" }
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "\u{2303}" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "\u{2325}" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "\u{21E7}" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "\u{2318}" }
        return s + Self.keyName(for: keyCode)
    }

    /// Human-readable name for a virtual key code, resolved through the active
    /// keyboard layout so that non-US layouts show the right character.
    static func keyName(for keyCode: UInt32) -> String {
        if let special = specialKeyNames[Int(keyCode)] { return special }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let dataRef = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(dataRef).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState, chars.count, &length, &chars
            )
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }

    private static let specialKeyNames: [Int: String] = [
        kVK_Return: "\u{21A9}", kVK_Tab: "\u{21E5}", kVK_Space: "Space",
        kVK_Delete: "\u{232B}", kVK_ForwardDelete: "\u{2326}", kVK_Escape: "\u{238B}",
        kVK_LeftArrow: "\u{2190}", kVK_RightArrow: "\u{2192}",
        kVK_UpArrow: "\u{2191}", kVK_DownArrow: "\u{2193}",
        kVK_Home: "\u{2196}", kVK_End: "\u{2198}",
        kVK_PageUp: "\u{21DE}", kVK_PageDown: "\u{21DF}",
    ].merging(functionKeys.mapValues { "F\($0)" }) { special, _ in special }

    /// Virtual key code to function key number.
    private static let functionKeys: [Int: Int] = [
        kVK_F1: 1, kVK_F2: 2, kVK_F3: 3, kVK_F4: 4, kVK_F5: 5, kVK_F6: 6, kVK_F7: 7,
        kVK_F8: 8, kVK_F9: 9, kVK_F10: 10, kVK_F11: 11, kVK_F12: 12, kVK_F13: 13,
        kVK_F14: 14, kVK_F15: 15, kVK_F16: 16, kVK_F17: 17, kVK_F18: 18, kVK_F19: 19, kVK_F20: 20,
    ]

    // MARK: - Menu key equivalents

    /// The `NSMenuItem.keyEquivalent` for this key, or nil when it has none.
    var menuKeyEquivalent: String? {
        if let number = Self.functionKeys[Int(keyCode)] {
            return Self.character(NSF1FunctionKey + number - 1)
        }
        if let special = Self.specialKeyEquivalents[Int(keyCode)] { return special }
        let name = Self.keyName(for: keyCode)
        return name == "?" ? nil : name.lowercased()
    }

    private static func character(_ scalar: Int) -> String {
        String(utf16CodeUnits: [UniChar(scalar)], count: 1)
    }

    private static let specialKeyEquivalents: [Int: String] = [
        kVK_Return: "\r", kVK_Tab: "\t", kVK_Space: " ",
        kVK_Delete: character(NSBackspaceCharacter), kVK_ForwardDelete: character(NSDeleteFunctionKey),
        kVK_Escape: "\u{1B}",
        kVK_LeftArrow: character(NSLeftArrowFunctionKey), kVK_RightArrow: character(NSRightArrowFunctionKey),
        kVK_UpArrow: character(NSUpArrowFunctionKey), kVK_DownArrow: character(NSDownArrowFunctionKey),
        kVK_Home: character(NSHomeFunctionKey), kVK_End: character(NSEndFunctionKey),
        kVK_PageUp: character(NSPageUpFunctionKey), kVK_PageDown: character(NSPageDownFunctionKey),
    ]

    // MARK: - Defaults storage

    var storageValue: String { "\(keyCode):\(carbonModifiers)" }

    init?(storageValue: String) {
        let parts = storageValue.split(separator: ":")
        guard parts.count == 2, let k = UInt32(parts[0]), let m = UInt32(parts[1]) else { return nil }
        self.keyCode = k
        self.carbonModifiers = m
    }
}
