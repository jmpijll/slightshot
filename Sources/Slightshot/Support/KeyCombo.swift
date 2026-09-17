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

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        // A bare key with no modifiers would swallow normal typing.
        guard carbon != 0 else { return nil }
        self.keyCode = UInt32(event.keyCode)
        self.carbonModifiers = carbon
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
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16",
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
