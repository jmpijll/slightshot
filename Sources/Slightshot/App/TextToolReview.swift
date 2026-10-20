import AppKit

/// A bounded synthetic native window for review; no capture, output, hotkeys or tray ownership.
/// Keyboard steps go through `NSApp.sendEvent`, the same routing a real key press takes.
final class TextToolReview: NSObject, NSApplicationDelegate, OverlayViewDelegate {
    private static let note = "Committed notes keep the wrapping and position they had while typing, "
        + "so a long review comment reads the same in the editor and in the export."
    private static let pasted = "Pasted with ⌘V through the Edit menu"

    private let directory: URL
    private var window: NSWindow?
    private var view: OverlayView?
    private var clipboard: [NSPasteboardItem] = []
    private var log = ""

    init(directory: URL) { self.directory = directory }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { NSApp.terminate(nil) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try show()
            try run(steps())
        } catch {
            fail(error)
        }
    }

    private func steps() -> [(name: String, action: () throws -> Void)] {
        [
            ("1-typing", { try self.beginText(at: CGPoint(x: 120, y: 150), typing: Self.note) }),
            ("2-committed", { try self.key("\r", code: 36) }),
            ("3-paste-ready", {
                try self.beginText(at: CGPoint(x: 120, y: 330), typing: "")
                self.clipboard = NSPasteboard.general.pasteboardItems?.map(Self.copy) ?? []
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Self.pasted, forType: .string)
            }),
            ("4-pasted", { try self.key("v", code: 9); self.restoreClipboard() }),
            ("5-select-all", { try self.key("a", code: 0) }),
            ("6-undo-paste", { try self.key("z", code: 6) }),
            ("7-redo-paste", { try self.key("z", code: 6, shift: true) }),
        ]
    }

    private func run(_ steps: [(name: String, action: () throws -> Void)]) throws {
        guard let step = steps.first else {
            try key("\r", code: 36)
            try key("c", code: 8)
            return
        }
        try step.action()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
            do {
                try snapshot(step.name)
                awaitCapture(of: step.name, deadline: Date().addingTimeInterval(10), then: Array(steps.dropFirst()))
            } catch { fail(error) }
        }
    }

    /// An external `screencapture` of the window writes `screen-<step>.png`; continue once it lands.
    private func awaitCapture(of name: String, deadline: Date,
                              then remaining: [(name: String, action: () throws -> Void)]) {
        let capture = directory.appendingPathComponent("screen-\(name).png")
        let captured = FileManager.default.fileExists(atPath: capture.path) || Date() >= deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + (captured ? 0.3 : 0.2)) { [self] in
            guard captured else { return awaitCapture(of: name, deadline: deadline, then: remaining) }
            do {
                focus()
                try run(remaining)
            } catch { fail(error) }
        }
    }

    /// Key events only reach the Edit menu while this app is active.
    private func focus() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func show() throws {
        guard let screen = NSScreen.main, let image = makeImage() else { throw CaptureError.noDisplays }
        let view = OverlayView(display: CapturedDisplay(screen: screen, displayID: screen.displayID,
                                                        image: image, scale: 1))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 560),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Slightshot text tool review"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 560)
        for subview in view.subviews { subview.frame = view.bounds }
        view.delegate = self
        self.window = window
        self.view = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try Data("\(window.windowNumber)".utf8).write(to: directory.appendingPathComponent("window-id.txt"))

        try mouse(.leftMouseDown, at: CGPoint(x: 80, y: 90))
        try mouse(.leftMouseDragged, at: CGPoint(x: 620, y: 470))
        try mouse(.leftMouseUp, at: CGPoint(x: 620, y: 470))
        guard let button = descendants(of: view).compactMap({ $0 as? ToolbarButton })
            .first(where: { $0.accessibilityLabel() == Tool.text.title }) else {
            throw CaptureError.failed("Missing text button")
        }
        button.performClick(nil)
    }

    private func beginText(at point: CGPoint, typing text: String) throws {
        try mouse(.leftMouseDown, at: point)
        try mouse(.leftMouseUp, at: point)
        guard let entry = window?.firstResponder as? TextEntryView else {
            throw CaptureError.failed("The text box did not take focus")
        }
        entry.insertText(text, replacementRange: NSRange(location: 0, length: 0))
    }

    private func key(_ character: String, code: UInt16, shift: Bool = false) throws {
        let typed = shift ? character.uppercased() : character
        guard let window, let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: shift ? [.command, .shift] : .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: typed, charactersIgnoringModifiers: typed, isARepeat: false, keyCode: code)
        else { throw CaptureError.failed("Missing key event") }
        log += "\(shift ? "⇧" : "")⌘\(character == "\r" ? "↩" : character.uppercased()) active=\(NSApp.isActive) "
            + "key=\(window.isKeyWindow) to=\(window.firstResponder.map { "\(type(of: $0))" } ?? "nil")\n"
        NSApp.sendEvent(event)
        try Data(log.utf8).write(to: directory.appendingPathComponent("keys.log"))
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint) throws {
        guard let view, let event = NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        else { throw CaptureError.failed("Missing mouse event") }
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        default: view.mouseUp(with: event)
        }
    }

    private func snapshot(_ name: String) throws {
        guard let view = window?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CaptureError.noDisplays }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try write(bitmap, name)
    }

    private func write(_ bitmap: NSBitmapImageRep, _ name: String) throws {
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CaptureError.noDisplays }
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }

    private static func copy(_ item: NSPasteboardItem) -> NSPasteboardItem {
        let copy = NSPasteboardItem()
        for type in item.types {
            if let data = item.data(forType: type) { copy.setData(data, forType: type) }
        }
        return copy
    }

    private func restoreClipboard() {
        guard NSPasteboard.general.string(forType: .string) == Self.pasted else { return }
        NSPasteboard.general.clearContents()
        if !clipboard.isEmpty { NSPasteboard.general.writeObjects(clipboard) }
        clipboard = []
    }

    private func fail(_ error: Error) {
        restoreClipboard()
        try? Data(error.localizedDescription.utf8).write(to: directory.appendingPathComponent("failure.txt"))
        NSApp.terminate(nil)
    }

    private func makeImage() -> CGImage? {
        guard let context = CGContext(data: nil, width: 900, height: 560, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: 560)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        NSColor(srgbRed: 0.08, green: 0.12, blue: 0.18, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 900, height: 560).fill()
        for row in 0..<7 {
            for column in 0..<9 {
                let hue = CGFloat((row * 9 + column) % 20) / 20
                NSColor(hue: hue, saturation: 0.3, brightness: 0.4, alpha: 1).setFill()
                NSBezierPath(roundedRect: CGRect(x: 90 + column * 58, y: 100 + row * 52, width: 50, height: 44),
                             xRadius: 6, yRadius: 6).fill()
            }
        }
        ("Review fixture · synthetic image" as NSString).draw(at: CGPoint(x: 90, y: 60), withAttributes: [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: NSColor.white,
        ])
        return context.makeImage()
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    func overlayDidCancel(_ view: OverlayView) { NSApp.terminate(nil) }
    func overlayDidTakeOver(_ view: OverlayView) {}
    func overlay(_ view: OverlayView, didComplete action: CaptureAction, image: CGImage) {
        try? write(NSBitmapImageRep(cgImage: image), "8-export")
        NSApp.terminate(nil)
    }
    func overlay(_ view: OverlayView, didRequestRecording selection: CGRect) {}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Sends every overlay shortcut from the README through `NSApp.sendEvent` while the
/// overlay, the palette slider or a toolbar button has focus, in both editor windows,
/// and writes what each key did to `shortcuts.md`. Output actions are only recorded.
final class TextToolShortcutCheck: NSObject, NSApplicationDelegate, OverlayViewDelegate {
    private struct Shortcut {
        let name: String, characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags
    }

    private static let shortcuts = [
        Shortcut(name: "⌘A select all", characters: "a", code: 0, modifiers: .command),
        Shortcut(name: "⌘C copy", characters: "c", code: 8, modifiers: .command),
        Shortcut(name: "⌘S save", characters: "s", code: 1, modifiers: .command),
        Shortcut(name: "⇧⌘S save as", characters: "S", code: 1, modifiers: [.command, .shift]),
        Shortcut(name: "⌘P print", characters: "p", code: 35, modifiers: .command),
        Shortcut(name: "⌘Z undo", characters: "z", code: 6, modifiers: .command),
        Shortcut(name: "⇧⌘Z redo", characters: "Z", code: 6, modifiers: [.command, .shift]),
        Shortcut(name: "Return confirm", characters: "\r", code: 36, modifiers: []),
        Shortcut(name: "Esc cancel", characters: "\u{1b}", code: 53, modifiers: []),
        Shortcut(name: "⌘X cancel", characters: "x", code: 7, modifiers: .command),
        Shortcut(name: "← move 1 pt", characters: "\u{F702}", code: 123, modifiers: [.numericPad, .function]),
        Shortcut(name: "⇧→ move 10 pt", characters: "\u{F703}", code: 124,
                 modifiers: [.numericPad, .function, .shift]),
    ]

    private let directory: URL
    private var actions: [CaptureAction] = []
    private var cancels = 0
    private var report = ""

    init(directory: URL) { self.directory = directory }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { NSApp.terminate(nil) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let screen = NSScreen.main, let image = Self.makeImage() else { throw CaptureError.noDisplays }
            let overlay = OverlayView(display: CapturedDisplay(screen: screen, displayID: screen.displayID,
                                                               image: image, scale: 1))
            let overlayWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 560),
                                         styleMask: [.titled], backing: .buffered, defer: false)
            overlayWindow.isReleasedWhenClosed = false
            overlayWindow.contentView = overlay
            overlay.frame = CGRect(x: 0, y: 0, width: 900, height: 560)
            for subview in overlay.subviews { subview.frame = overlay.bounds }
            overlay.delegate = self
            try drag(overlay, from: CGPoint(x: 80, y: 90), to: CGPoint(x: 620, y: 470))

            let clipboard = OverlayView(source: .clipboard(image, fitting: CGSize(width: 900, height: 560)))
            clipboard.delegate = self
            let clipboardWindow = ClipboardEditorWindow(editor: clipboard)

            report = "| Shortcut | Window | Focus | Result |\n| --- | --- | --- | --- |\n"
            rows = try self.rows(overlay, in: overlayWindow, label: "Capture overlay")
                + rows(clipboard, in: clipboardWindow, label: "Clipboard editor")
            runNextRow()
        } catch {
            finish(error)
        }
    }

    private struct Row {
        let view: OverlayView, window: NSWindow, label: String, focus: String, responder: NSResponder
        let shortcut: Shortcut
    }

    private var rows: [Row] = []

    private func rows(_ view: OverlayView, in window: NSWindow, label: String) throws -> [Row] {
        window.center()
        guard let swatch = descendants(of: window.contentView).compactMap({ $0 as? ColorSwatchButton }).first else {
            throw CaptureError.failed("Missing colour button")
        }
        swatch.performClick(nil)
        let views = descendants(of: window.contentView)
        guard let slider = views.compactMap({ $0 as? NSSlider }).first,
              let button = views.compactMap({ $0 as? ToolbarButton }).first(where: {
                  $0.accessibilityLabel() == Tool.pen.title }) else { throw CaptureError.failed("Missing controls") }
        let focuses: [(String, NSResponder)] = [
            ("Overlay", view), ("Palette slider", slider), ("Toolbar button", button),
        ]
        return focuses.flatMap { focus, responder in
            Self.shortcuts.map {
                Row(view: view, window: window, label: label, focus: focus, responder: responder, shortcut: $0)
            }
        }
    }

    /// One row per run-loop turn, and only once the app is active and its window key.
    private func runNextRow(attempt: Int = 0) {
        guard let row = rows.first else { return finish(nil) }
        row.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard NSApp.isActive, row.window.isKeyWindow || attempt > 40 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in runNextRow(attempt: attempt + 1) }
            return
        }
        do {
            try run(row)
        } catch {
            return finish(error)
        }
        rows.removeFirst()
        if rows.first?.window !== row.window { row.window.orderOut(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in runNextRow() }
    }

    private func run(_ row: Row) throws {
        try prepare(row.view, in: row.window, redo: row.shortcut.characters == "Z")
        let focused = row.window.makeFirstResponder(row.responder)
        let before = (selection: row.view.canvas.selection, count: row.view.annotations.count)
        actions = []
        cancels = 0
        let shortcut = row.shortcut
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shortcut.modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: row.window.windowNumber, context: nil,
            characters: shortcut.characters, charactersIgnoringModifiers: shortcut.characters,
            isARepeat: false, keyCode: shortcut.code) else { throw CaptureError.failed("Missing key event") }
        let key = NSApp.isActive && row.window.isKeyWindow
        NSApp.sendEvent(event)
        report += "| \(shortcut.name) | \(row.label) | \(row.focus)\(focused ? "" : " (refused focus)")"
            + "\(key ? "" : " (window not key)") | \(describe(before: before, view: row.view)) |\n"
    }

    private func finish(_ error: Error?) {
        if let error {
            try? Data(error.localizedDescription.utf8).write(to: directory.appendingPathComponent("failure.txt"))
        } else {
            try? Data(report.utf8).write(to: directory.appendingPathComponent("shortcuts.md"))
        }
        NSApp.terminate(nil)
    }

    /// A smaller selection than the image and one undoable (or, for Redo, one undone)
    /// rectangle, so every key has a visible effect.
    private func prepare(_ view: OverlayView, in window: NSWindow, redo: Bool) throws {
        if view.annotations.isEmpty {
            try choose(.rectangle, in: window)
            try drag(view, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 320, y: 300))
            try choose(.rectangle, in: window)
        }
        if redo, view.undoneAnnotations.isEmpty { view.undo() }
        if let selection = view.canvas.selection, selection.minX != 120 || selection.minY != 130 {
            try drag(view, from: selection.origin, to: CGPoint(x: 120, y: 130))
        }
        if let selection = view.canvas.selection, selection.maxX != 420 || selection.maxY != 330 {
            try drag(view, from: CGPoint(x: selection.maxX, y: selection.maxY), to: CGPoint(x: 420, y: 330))
        }
    }

    private func describe(before: (selection: CGRect?, count: Int), view: OverlayView) -> String {
        var effects: [String] = actions.map { "\($0)" }
        if cancels > 0 { effects.append("cancel") }
        if let old = before.selection, let new = view.canvas.selection, old != new {
            effects.append(old.size == new.size
                ? "moved \(Int(new.minX - old.minX)),\(Int(new.minY - old.minY))"
                : "selection \(Int(new.width))×\(Int(new.height))")
        }
        let count = view.annotations.count
        if count < before.count { effects.append("undo") }
        if count > before.count { effects.append("redo") }
        return effects.isEmpty ? "nothing" : effects.joined(separator: ", ")
    }

    private func choose(_ tool: Tool, in window: NSWindow) throws {
        guard let button = descendants(of: window.contentView).compactMap({ $0 as? ToolbarButton })
            .first(where: { $0.accessibilityLabel() == tool.title }) else { throw CaptureError.failed("Missing tool") }
        button.performClick(nil)
    }

    private func drag(_ view: OverlayView, from start: CGPoint, to end: CGPoint) throws {
        for (type, point) in [(NSEvent.EventType.leftMouseDown, start), (.leftMouseDragged, end), (.leftMouseUp, end)] {
            guard let event = NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? 0,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { throw CaptureError.failed("Mouse") }
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            default: view.mouseUp(with: event)
            }
        }
    }

    private func descendants(of view: NSView?) -> [NSView] {
        view.map { $0.subviews.flatMap { [$0] + descendants(of: $0) } } ?? []
    }

    private static func makeImage() -> CGImage? {
        guard let context = CGContext(data: nil, width: 900, height: 560, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0.12, green: 0.16, blue: 0.22, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 900, height: 560))
        return context.makeImage()
    }

    func overlayDidCancel(_ view: OverlayView) { cancels += 1 }
    func overlayDidTakeOver(_ view: OverlayView) {}
    func overlay(_ view: OverlayView, didComplete action: CaptureAction, image: CGImage) { actions.append(action) }
    func overlay(_ view: OverlayView, didRequestRecording selection: CGRect) {}
}
