import AppKit
import Testing
@testable import Slightshot

/// Real key events matched by the Edit menu, as typed into an ordinary text field
/// such as the video editor's time fields or the Settings filename field. The test
/// runner has no key window, so a recorder stands in for the focused field; the
/// native `--text-tool-shortcuts` check covers the edit itself.
@MainActor @Suite(.serialized)
struct EditMenuDispatchTests {
    @Test func everyEditKeyReachesItsAction() throws {
        let edit = try #require(EditMenu.makeMainMenu().items.last?.submenu)
        let recorder = Recorder()
        for item in edit.items where !item.isSeparatorItem { item.target = recorder }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 60),
                              styleMask: .titled, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let keys: [(characters: String, shift: Bool, code: UInt16, action: String)] = [
            ("z", false, 6, "undo:"), ("Z", true, 6, "redo:"), ("x", false, 7, "cut:"),
            ("c", false, 8, "copy:"), ("v", false, 9, "paste:"), ("a", false, 0, "selectAll:"),
        ]
        for key in keys {
            recorder.sent = []
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: key.shift ? [.command, .shift] : .command, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: key.characters,
                charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.code))
            #expect(edit.performKeyEquivalent(with: event), "\(key.action) matches a menu item")
            #expect(recorder.sent == [key.action], "\(key.shift ? "⇧" : "")⌘\(key.characters.uppercased())")
        }
    }

    private final class Recorder: NSObject, NSMenuItemValidation {
        var sent: [String] = []
        func validateMenuItem(_ item: NSMenuItem) -> Bool { true }
        @objc func undo(_ sender: Any?) { sent.append("undo:") }
        @objc func redo(_ sender: Any?) { sent.append("redo:") }
        @objc func cut(_ sender: Any?) { sent.append("cut:") }
        @objc func copy(_ sender: Any?) { sent.append("copy:") }
        @objc func paste(_ sender: Any?) { sent.append("paste:") }
        @objc func selectAll(_ sender: Any?) { sent.append("selectAll:") }
    }
}
