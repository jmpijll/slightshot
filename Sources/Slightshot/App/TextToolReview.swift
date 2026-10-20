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
