import AppKit
import Carbon.HIToolbox
import Observation
import OSLog

/// The capture actions a user can bind to a global shortcut.
nonisolated enum HotKeyAction: CaseIterable, Sendable {
    case captureArea, saveFullScreen, copyFullScreen

    var title: String {
        switch self {
        case .captureArea: "Capture area"
        case .saveFullScreen: "Capture full screen"
        case .copyFullScreen: "Copy full screen"
        }
    }
}

/// Why a recorded combination cannot become a global shortcut.
nonisolated enum ShortcutRejection: Equatable, Sendable {
    case interceptsTyping
    case duplicate(HotKeyAction)
    case unavailable

    /// Checks a combination for `action` against the other actions' shortcuts.
    /// Registration is checked separately, by `HotKeyCenter.rejection`.
    static func check(_ combo: KeyCombo, for action: HotKeyAction,
                      assigned: [HotKeyAction: KeyCombo]) -> ShortcutRejection? {
        guard !combo.isEmpty else { return nil }
        if combo.interceptsTyping { return .interceptsTyping }
        let owner = HotKeyAction.allCases.first { $0 != action && assigned[$0] == combo }
        return owner.map(ShortcutRejection.duplicate)
    }

    func message(for combo: KeyCombo) -> String {
        switch self {
        case .interceptsTyping: "\(combo.displayString) would block typing. Include ⌘ or ⌃."
        case .duplicate(let owner): "\(combo.displayString) is already used by \(owner.title)."
        case .unavailable: "\(combo.displayString) is reserved by macOS or another app."
        }
    }
}

/// Registers system-wide hotkeys through Carbon's `RegisterEventHotKey`.
///
/// This is the only global-shortcut API that does **not** require Accessibility
/// access, which matters a lot for a screenshot tool: the app should work the
/// moment it launches, with only the Screen Recording prompt to clear.
@Observable
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    /// Actions whose shortcut could not be registered by the last reload.
    private(set) var unavailable: Set<HotKeyAction> = []

    @ObservationIgnored private var bindings: [HotKeyAction: (KeyCombo, () -> Void)] = [:]
    @ObservationIgnored private var isSuspended = false
    @ObservationIgnored private var actions: [UInt32: () -> Void] = [:]
    @ObservationIgnored private var refs: [UInt32: EventHotKeyRef] = [:]
    @ObservationIgnored private var nextID: UInt32 = 1
    @ObservationIgnored private var eventHandler: EventHandlerRef?

    private init() {}

    /// Replaces every registration with `bindings`, skipping empty combos.
    func reload(_ bindings: [HotKeyAction: (KeyCombo, () -> Void)]) {
        self.bindings = bindings
        registerBindings()
    }

    /// Releases the shortcuts while the Settings recorder listens, so pressing
    /// one is recorded instead of starting a capture.
    func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        registerBindings()
    }

    /// Why `combo` cannot become the shortcut for `action`, or nil if it can.
    func rejection(for combo: KeyCombo, action: HotKeyAction,
                   assigned: [HotKeyAction: KeyCombo]) -> ShortcutRejection? {
        if let rejection = ShortcutRejection.check(combo, for: action, assigned: assigned) { return rejection }
        guard !combo.isEmpty, combo != assigned[action] else { return nil }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers,
                                         EventHotKeyID(signature: Self.signature, id: 0),
                                         GetApplicationEventTarget(), Self.options, &ref)
        guard status == noErr, let ref else { return .unavailable }
        UnregisterEventHotKey(ref)
        return nil
    }

    private func registerBindings() {
        unregisterAll()
        guard !isSuspended else { return }
        installHandlerIfNeeded()

        var failures: Set<HotKeyAction> = []
        for action in HotKeyAction.allCases {
            guard let (combo, handler) = bindings[action], !combo.isEmpty else { continue }
            if !register(combo, action: handler) { failures.insert(action) }
        }
        if unavailable != failures { unavailable = failures }
    }

    private func register(_ combo: KeyCombo, action: @escaping () -> Void) -> Bool {
        let id = nextID
        nextID &+= 1

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            combo.keyCode, combo.carbonModifiers, hotKeyID,
            GetApplicationEventTarget(), Self.options, &ref
        )
        guard status == noErr, let ref else {
            Log.hotkeys.error("Could not register \(combo.displayString, privacy: .public) (OSStatus \(status))")
            return false
        }
        actions[id] = action
        refs[id] = ref
        Log.debug("Registered \(combo.displayString)", Log.hotkeys)
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
    /// Without exclusivity Carbon accepts combos macOS keeps for itself, such as
    /// ⌘Space and ⌘Tab, and they never fire. Exclusive registration fails instead.
    private static let options = OptionBits(kEventHotKeyExclusive)
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
