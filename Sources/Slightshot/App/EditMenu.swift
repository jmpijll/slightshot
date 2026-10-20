import AppKit

/// An accessory app never shows its menu bar, but AppKit still routes key
/// equivalents through the main menu, and that is what gives text fields ⌘X,
/// ⌘C, ⌘V, ⌘A and ⌘Z. A matching item swallows its key even when it cannot
/// act, so views with their own ⌘ shortcuts claim them in `performKeyEquivalent`.
enum EditMenu {
    static func makeMainMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        // Shift is written as the uppercase letter; "z" plus a Shift mask never matches ⇧⌘Z.
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let main = NSMenu()
        // AppKit treats the first item as the application menu.
        main.addItem(NSMenuItem())
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }
}
