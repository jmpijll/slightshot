import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Slightshot

@MainActor
struct ShortcutValidationTests {
    private func combo(_ key: Int, _ modifiers: Int = 0) -> KeyCombo {
        KeyCombo(keyCode: UInt32(key), carbonModifiers: UInt32(modifiers))
    }

    @Test func typingModifiersAloneAreRejectedForCharacterKeys() {
        for modifiers in [0, shiftKey, optionKey, shiftKey | optionKey] {
            #expect(combo(kVK_ANSI_A, modifiers).interceptsTyping)
            #expect(combo(kVK_Space, modifiers).interceptsTyping)
        }
        for modifiers in [cmdKey, controlKey, cmdKey | shiftKey, controlKey | optionKey] {
            #expect(!combo(kVK_ANSI_A, modifiers).interceptsTyping)
        }
        #expect(!combo(kVK_F13).interceptsTyping)
        #expect(!combo(kVK_F5, shiftKey).interceptsTyping)
        #expect(ShortcutRejection.check(combo(kVK_ANSI_A, shiftKey), for: .captureArea, assigned: [:])
            == .interceptsTyping)
    }

    @Test func shortcutsAlreadyUsedByAnotherActionAreRejected() {
        let assigned: [HotKeyAction: KeyCombo] = [
            .captureArea: .captureArea, .saveFullScreen: .saveFullScreen, .copyFullScreen: .none,
        ]
        #expect(ShortcutRejection.check(.saveFullScreen, for: .captureArea, assigned: assigned)
            == .duplicate(.saveFullScreen))
        #expect(ShortcutRejection.check(.captureArea, for: .captureArea, assigned: assigned) == nil)
        #expect(ShortcutRejection.check(.none, for: .saveFullScreen, assigned: assigned) == nil)
        #expect(ShortcutRejection.check(.copyFullScreen, for: .captureArea, assigned: assigned) == nil)
        #expect(ShortcutRejection.duplicate(.saveFullScreen).message(for: .saveFullScreen)
            == "⇧⌘8 is already used by Capture full screen.")
    }

    @Test func menuKeyEquivalentsUseAppKitCharacters() {
        func character(_ value: Int) -> String { String(utf16CodeUnits: [UniChar(value)], count: 1) }
        #expect(combo(kVK_F5, cmdKey).menuKeyEquivalent == character(NSF5FunctionKey))
        #expect(combo(kVK_F13).menuKeyEquivalent == character(NSF13FunctionKey))
        #expect(combo(kVK_F20).menuKeyEquivalent == character(NSF20FunctionKey))
        #expect(combo(kVK_Space, cmdKey).menuKeyEquivalent == " ")
        #expect(combo(kVK_Return, cmdKey).menuKeyEquivalent == "\r")
        #expect(combo(kVK_LeftArrow, cmdKey).menuKeyEquivalent == character(NSLeftArrowFunctionKey))
        #expect(combo(kVK_UpArrow, cmdKey).menuKeyEquivalent == character(NSUpArrowFunctionKey))
        #expect(combo(kVK_F13).displayString == "F13")
    }

    @Test func registrationFailuresAndSuspensionAreVisible() {
        let center = HotKeyCenter.shared
        let shortcut = combo(kVK_F19, cmdKey | controlKey | optionKey | shiftKey)
        defer { center.reload([:]) }

        center.reload([.captureArea: (shortcut, {}), .saveFullScreen: (shortcut, {})])
        #expect(center.unavailable == [.saveFullScreen])
        #expect(center.rejection(for: shortcut, action: .copyFullScreen, assigned: [:]) == .unavailable)

        center.setSuspended(true)
        #expect(center.rejection(for: shortcut, action: .copyFullScreen, assigned: [:]) == nil)
        center.setSuspended(false)
        #expect(center.rejection(for: shortcut, action: .copyFullScreen, assigned: [:]) == .unavailable)

        center.reload([.captureArea: (shortcut, {})])
        #expect(center.unavailable.isEmpty)
    }

    @Test func bareCharacterKeyIsRefusedNotTreatedAsClear() throws {
        let bareA = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false,
            keyCode: UInt16(kVK_ANSI_A)
        ))
        #expect(ShortcutRejection.check(KeyCombo(event: bareA), for: .captureArea, assigned: [:])
            == .interceptsTyping)
    }

    /// Another app holding a combo exclusively must not stop Slightshot from
    /// registering it, and Slightshot keeps it after that app quits.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")))
    func anotherAppsExclusiveHotKeyDoesNotBlockRegistration() throws {
        let center = HotKeyCenter.shared
        let shortcut = combo(kVK_F18, cmdKey | controlKey | optionKey | shiftKey)
        defer { center.reload([:]) }

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        helper.arguments = ["-c", Self.exclusiveHotKeyHolder, "\(shortcut.keyCode)", "\(shortcut.carbonModifiers)"]
        let input = Pipe()
        let output = Pipe()
        helper.standardInput = input
        helper.standardOutput = output
        try helper.run()
        defer { if helper.isRunning { helper.terminate() } }
        let status = String(data: output.fileHandleForReading.availableData, encoding: .utf8)
        #expect(status?.trimmingCharacters(in: .whitespacesAndNewlines) == "0")

        center.reload([.captureArea: (shortcut, {})])
        #expect(center.unavailable.isEmpty)

        try input.fileHandleForWriting.close()
        helper.waitUntilExit()
        #expect(center.unavailable.isEmpty)
        #expect(center.rejection(for: shortcut, action: .copyFullScreen, assigned: [:]) == .unavailable)
    }

    /// Registers argv[1]:argv[2] exclusively, prints the OSStatus and holds it until stdin closes.
    private static let exclusiveHotKeyHolder = """
    import ctypes, sys
    carbon = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/Carbon.framework/Carbon")
    class HotKeyID(ctypes.Structure):
        _fields_ = [("signature", ctypes.c_uint32), ("id", ctypes.c_uint32)]
    carbon.GetApplicationEventTarget.restype = ctypes.c_void_p
    carbon.RegisterEventHotKey.restype = ctypes.c_int32
    carbon.RegisterEventHotKey.argtypes = [ctypes.c_uint32, ctypes.c_uint32, HotKeyID, ctypes.c_void_p,
                                           ctypes.c_uint32, ctypes.POINTER(ctypes.c_void_p)]
    ref = ctypes.c_void_p()
    status = carbon.RegisterEventHotKey(int(sys.argv[1]), int(sys.argv[2]), HotKeyID(0x54455354, 1),
                                        carbon.GetApplicationEventTarget(), 1, ctypes.byref(ref))
    print(status, flush=True)
    sys.stdin.read()
    """
}
