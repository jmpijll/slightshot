import AppKit
import Carbon.HIToolbox
import OSLog

/// Registers system-wide hotkeys through Carbon's `RegisterEventHotKey`.
///
/// This is the only global-shortcut API that does **not** require Accessibility
/// access, which matters a lot for a screenshot tool: the app should work the
/// moment it launches, with only the Screen Recording prompt to clear.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    private init() {}

    /// Replaces every registration with `combos`, skipping empty or duplicate keys.
    /// Returns the combos that could not be claimed (already taken by another app).
    @discardableResult
    func reload(_ combos: [(KeyCombo, () -> Void)]) -> [KeyCombo] {
        unregisterAll()
        installHandlerIfNeeded()

        var failures: [KeyCombo] = []
        var seen = Set<KeyCombo>()
        for (combo, action) in combos {
            guard !combo.isEmpty, seen.insert(combo).inserted else { continue }
            if !register(combo, action: action) { failures.append(combo) }
        }
        return failures
    }

    private func register(_ combo: KeyCombo, action: @escaping () -> Void) -> Bool {
        let id = nextID
        nextID &+= 1

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            combo.keyCode, combo.carbonModifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else {
            Log.hotkeys.error("Could not register \(combo.displayString, privacy: .public) (OSStatus \(status))")
            return false
        }
        actions[id] = action
        refs[id] = ref
        return true
    }

    func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
        actions.removeAll()
    }

    fileprivate func fire(id: UInt32) {
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), slightshotHotKeyHandler, 1, &spec, nil, &eventHandler)
    }

    /// Four-char code 'SLSH'.
    nonisolated static let signature: OSType = 0x534C_5348
}

private nonisolated func slightshotHotKeyHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == HotKeyCenter.signature else { return status }

    let id = hotKeyID.id
    DispatchQueue.main.async {
        MainActor.assumeIsolated { HotKeyCenter.shared.fire(id: id) }
    }
    return noErr
}
