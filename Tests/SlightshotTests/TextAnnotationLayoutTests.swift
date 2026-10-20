import AppKit
import Testing
@testable import Slightshot

@MainActor @Suite(.serialized)
struct TextAnnotationLayoutTests {
    private static let note = "This long review note wraps across several lines while it is being typed"
    private static let ink = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)

    @Test func committedScreenshotTextKeepsTheTypedWrapAndPosition() throws {
        let editor = try OverlayEditor()
        defer { editor.window.close() }
        editor.view.toolbarDidChangeColor(Self.ink)
        try editor.choose(.text)
        try editor.press(at: CGPoint(x: 24, y: 50))
        let entry = try #require(editor.view.subviews.compactMap { $0 as? TextEntryView }.first)
        entry.string = Self.note
        entry.didChangeText()
        let typed = try #require(inkBounds(snapshot(editor.view)))
        #expect(typed.height > 3 * 18, "the typed note wraps onto at least three lines")

        editor.view.commitTextEntry()
        let canvas = snapshot(editor.view)
        let export = try editor.export()
        let committed = try #require(inkBounds(canvas))
        let exported = try #require(inkBounds(export)).offsetBy(dx: OverlayEditor.selection.minX,
                                                                 dy: OverlayEditor.selection.minY)
        #expect(committed.isClose(to: typed, within: 1), "canvas \(committed) vs typed \(typed)")
        #expect(exported.isClose(to: typed, within: 1), "export \(exported) vs typed \(typed)")
        #expect(inkMismatches(canvas, export, in: typed.insetBy(dx: -4, dy: -4),
                              offset: OverlayEditor.selection.origin) == 0,
                "the exported glyph pixels match the canvas")

        let annotation = try #require(editor.annotations.last)
        #expect(annotation.dirtyBounds.contains(committed))
        #expect(annotation.dirtyBounds.width < committed.width + 2 * 24 + 12,
                "dirty bounds follow the wrapped size, not one long line")
    }

    @Test func committedVideoTextKeepsTheTypedWrapAndPosition() throws {
        let source = CGSize(width: 640, height: 360)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 180),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let canvas = VideoCanvasView(sourceSize: source)
        window.contentView = canvas
        canvas.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        canvas.showFrame(try solidImage(size: source), at: 0)
        canvas.tool = .text
        canvas.color = Self.ink
        canvas.fontSize = 14
        var committed: Annotation?
        canvas.onCommit = { committed = $0 }

        canvas.mouseDown(with: try mouseEvent(at: CGPoint(x: 20, y: 24), in: canvas))
        let entry = try #require(canvas.subviews.compactMap { $0 as? TextEntryView }.first)
        entry.string = Self.note
        entry.didChangeText()
        let typed = try #require(inkBounds(snapshot(canvas)))
        #expect(typed.height > 2 * 14, "the typed note wraps onto at least two lines")

        canvas.commitTextEntry()
        let annotation = try #require(committed)
        canvas.annotations = [VideoAnnotation(annotation: annotation, start: 0, end: 1)]
        canvas.refresh()
        let shown = try #require(inkBounds(snapshot(canvas)))
        #expect(shown.isClose(to: typed, within: 1.5), "preview \(shown) vs typed \(typed)")
    }

    @Test func editMenuServesTextFieldsAndLeavesOverlayShortcutsToTheOverlay() throws {
        let edit = try #require(EditMenu.makeMainMenu().items.last?.submenu)
        let items = edit.items.filter { !$0.isSeparatorItem }
        #expect(items.map(\.title) == ["Undo", "Redo", "Cut", "Copy", "Paste", "Select All"])
        #expect(items.map(\.keyEquivalent) == ["z", "z", "x", "c", "v", "a"])
        #expect(items[1].keyEquivalentModifierMask == [.command, .shift])

        let editor = try OverlayEditor()
        defer { editor.window.close() }
        try editor.choose(.text)
        try editor.press(at: CGPoint(x: 24, y: 50))
        let entry = try #require(editor.view.subviews.compactMap { $0 as? TextEntryView }.first)
        entry.insertText("typed", replacementRange: NSRange(location: 0, length: 0))
        entry.setSelectedRange(NSRange(location: 0, length: 2))
        for item in items where ["Cut", "Copy", "Select All"].contains(item.title) {
            #expect(enabledTarget(for: item, from: entry) === entry, "\(item.title) acts on the text box")
        }
        // Paste validation reads the user's clipboard, which tests leave alone.
        let paste = #selector(NSText.paste(_:))
        #expect(items[4].action == paste && entry.responds(to: paste))

        for key in ["a", "c", "x", "z"] {
            #expect(!editor.view.performKeyEquivalent(with: try editor.commandKey(key)),
                    "⌘\(key.uppercased()) reaches the Edit menu while the text box has focus")
        }

        editor.view.commitTextEntry()
        #expect(editor.window.firstResponder === editor.view)
        #expect(editor.view.performKeyEquivalent(with: try editor.commandKey("c")),
                "the overlay claims ⌘C before the Edit menu can swallow it")
        #expect(editor.exported != nil)
    }

    // MARK: - Fixtures

    private final class OverlayEditor: OverlayViewDelegate {
        static let selection = CGRect(x: 10, y: 10, width: 300, height: 180)
        let window: NSWindow
        let view: OverlayView
        private var image: CGImage?

        var annotations: [Annotation] { view.annotations }

        init() throws {
            let size = CGSize(width: 420, height: 260)
            let screen = try #require(NSScreen.main)
            view = OverlayView(display: CapturedDisplay(screen: screen, displayID: screen.displayID,
                image: try solidImage(size: size), scale: 1))
            window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: .borderless, backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = view
            view.frame = CGRect(origin: .zero, size: size)
            view.delegate = self
            view.mouseDown(with: try mouseEvent(at: Self.selection.origin, in: view))
            view.mouseDragged(with: try mouseEvent(.leftMouseDragged,
                at: CGPoint(x: Self.selection.maxX, y: Self.selection.maxY), in: view))
            view.mouseUp(with: try mouseEvent(.leftMouseUp,
                at: CGPoint(x: Self.selection.maxX, y: Self.selection.maxY), in: view))
        }

        func choose(_ tool: Tool) throws {
            let button = try #require(descendants(of: view).compactMap { $0 as? ToolbarButton }
                .first { $0.accessibilityLabel() == tool.title })
            if !button.isSelectedItem { button.performClick(nil) }
        }

        func press(at point: CGPoint) throws { view.mouseDown(with: try mouseEvent(at: point, in: view)) }

        var exported: CGImage? { image }

        func export() throws -> NSBitmapImageRep {
            view.keyDown(with: try commandKey("c"))
            return NSBitmapImageRep(cgImage: try #require(image))
        }

        func commandKey(_ character: String) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0))
        }

        private func descendants(of view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants(of: $0) }
        }

        func overlayDidCancel(_ view: OverlayView) {}
        func overlayDidTakeOver(_ view: OverlayView) {}
        func overlay(_ view: OverlayView, didComplete action: CaptureAction, image: CGImage) { self.image = image }
        func overlay(_ view: OverlayView, didRequestRecording selection: CGRect) {}
    }
}

/// The responder AppKit's menu dispatch would send `item` to, if it is enabled.
@MainActor private func enabledTarget(for item: NSMenuItem, from responder: NSResponder) -> NSResponder? {
    var current: NSResponder? = responder
    while let candidate = current {
        if let action = item.action, candidate.responds(to: action) {
            let enabled = (candidate as? NSMenuItemValidation)?.validateMenuItem(item) ?? true
            return enabled ? candidate : nil
        }
        current = candidate.nextResponder
    }
    return nil
}

private func solidImage(size: CGSize) throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: Int(size.width), height: Int(size.height),
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(srgbRed: 0.15, green: 0.1, blue: 0.3, alpha: 1))
    context.fill(CGRect(origin: .zero, size: size))
    return try #require(context.makeImage())
}

@MainActor private func mouseEvent(_ type: NSEvent.EventType = .leftMouseDown, at point: CGPoint,
                                   in view: NSView) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
        timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil,
        eventNumber: 0, clickCount: 1, pressure: 1))
}

/// One bitmap pixel per view point, so pixel coordinates are view coordinates.
@MainActor private func snapshot(_ view: NSView) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width),
        pixelsHigh: Int(view.bounds.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = view.bounds.size
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

private func rgb(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> (CGFloat, CGFloat, CGFloat) {
    let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) ?? .black
    return (color.redComponent, color.greenComponent, color.blueComponent)
}

/// Bright green glyph cores; the dark text shadow and the background never qualify.
private func isInk(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> Bool {
    let (red, green, blue) = rgb(rep, x, y)
    return green > 0.6 && red < 0.35 && blue < 0.45
}

/// Bounds of the glyph cores, in top-left pixel coordinates.
private func inkBounds(_ rep: NSBitmapImageRep) -> CGRect? {
    var box: CGRect?
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide where isInk(rep, x, y) {
            let pixel = CGRect(x: x, y: y, width: 1, height: 1)
            box = box.map { $0.union(pixel) } ?? pixel
        }
    }
    return box
}

/// Counts glyph pixels in either image with no glyph pixel within one pixel in the
/// other, which tolerates antialiasing but not a shifted or rewrapped line.
/// Export pixels are shifted by the selection origin.
private func inkMismatches(_ view: NSBitmapImageRep, _ export: NSBitmapImageRep, in rect: CGRect,
                           offset: CGPoint) -> Int {
    let dx = Int(offset.x), dy = Int(offset.y)
    let area = rect.integral.intersection(CGRect(x: offset.x + 1, y: offset.y + 1,
                                                 width: CGFloat(export.pixelsWide - 2),
                                                 height: CGFloat(export.pixelsHigh - 2)))
    func near(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> Bool {
        (-1...1).contains { oy in (-1...1).contains { ox in isInk(rep, x + ox, y + oy) } }
    }
    var mismatches = 0
    for y in Int(area.minY)..<Int(area.maxY) {
        for x in Int(area.minX)..<Int(area.maxX) {
            if isInk(view, x, y), !near(export, x - dx, y - dy) { mismatches += 1 }
            if isInk(export, x - dx, y - dy), !near(view, x, y) { mismatches += 1 }
        }
    }
    return mismatches
}

private extension CGRect {
    func isClose(to other: CGRect, within tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(maxX - other.maxX) <= tolerance && abs(maxY - other.maxY) <= tolerance
    }
}
