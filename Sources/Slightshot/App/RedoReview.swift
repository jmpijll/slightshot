import AppKit

/// A bounded synthetic native window for review; no capture, output, hotkeys or tray ownership.
final class RedoReview: NSObject, NSApplicationDelegate, OverlayViewDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) { NSApp.terminate(nil) }
        } catch {
            Log.app.error("Redo review failed: \(error.localizedDescription, privacy: .public)")
            NSApp.terminate(nil)
        }
    }

    private func show() throws {
        guard let screen = NSScreen.main, let image = makeImage() else {
            throw CaptureError.noDisplays
        }
        let view = OverlayView(display: CapturedDisplay(screen: screen, displayID: screen.displayID,
                                                        image: image, scale: 1))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Slightshot redo review"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        view.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        for subview in view.subviews { subview.frame = view.bounds }
        view.delegate = self
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        try gesture(from: CGPoint(x: 100, y: 80), to: CGPoint(x: 870, y: 600), in: view)
        try choose(.rectangle, in: view)
        try gesture(from: CGPoint(x: 180, y: 180), to: CGPoint(x: 500, y: 340), in: view)
        try choose(.pixelate, in: view)
        try gesture(from: CGPoint(x: 220, y: 200), to: CGPoint(x: 380, y: 300), in: view)
        try choose(.step, in: view)
        try gesture(from: CGPoint(x: 580, y: 250), to: nil, in: view)
        try gesture(from: CGPoint(x: 690, y: 375), to: nil, in: view)
        window.makeFirstResponder(view)
    }

    private func makeImage() -> CGImage? {
        guard let context = CGContext(data: nil, width: 1000, height: 700, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: 700)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        NSColor(srgbRed: 0.08, green: 0.12, blue: 0.18, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 1000, height: 700).fill()
        for row in 0..<6 {
            for column in 0..<9 {
                let hue = CGFloat((row * 9 + column) % 20) / 20
                NSColor(hue: hue, saturation: 0.35, brightness: 0.55, alpha: 1).setFill()
                NSBezierPath(roundedRect: CGRect(x: 150 + column * 72, y: 155 + row * 60,
                                                width: 64, height: 52), xRadius: 8, yRadius: 8).fill()
            }
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: NSColor.white,
        ]
        ("Undo and Redo · committed annotations" as NSString)
            .draw(at: CGPoint(x: 130, y: 110), withAttributes: attributes)
        ("⌘Z to remove step 2   ·   ⇧⌘Z to restore it" as NSString)
            .draw(at: CGPoint(x: 130, y: 530), withAttributes: attributes)
        return context.makeImage()
    }

    private func choose(_ tool: Tool, in view: OverlayView) throws {
        guard let button = descendants(of: view).compactMap({ $0 as? ToolbarButton })
            .first(where: { $0.accessibilityLabel() == tool.title }) else {
            throw CaptureError.failed("Missing \(tool.title) button")
        }
        if !button.isSelectedItem { button.performClick(nil) }
    }

    private func gesture(from start: CGPoint, to end: CGPoint?, in view: OverlayView) throws {
        view.mouseDown(with: try mouse(.leftMouseDown, at: start, in: view))
        if let end { view.mouseDragged(with: try mouse(.leftMouseDragged, at: end, in: view)) }
        view.mouseUp(with: try mouse(.leftMouseUp, at: end ?? start, in: view))
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in view: OverlayView) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1) else { throw CaptureError.failed("Missing mouse event") }
        return event
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    func overlayDidCancel(_ view: OverlayView) { NSApp.terminate(nil) }
    func overlayDidTakeOver(_ view: OverlayView) {}
    func overlay(_ view: OverlayView, didComplete action: CaptureAction, image: CGImage) {}
    func overlay(_ view: OverlayView, didRequestRecording selection: CGRect) {}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
