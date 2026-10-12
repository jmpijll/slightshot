import AppKit

/// Automated interaction over a synthetic source in the production native editors.
final class AnnotationSizeReview: NSObject, NSApplicationDelegate, OverlayViewDelegate {
    private var windows: [NSWindow] = []
    private let directory: URL
    private var originalWidth: Double = 3
    private var originalFont: Double = 18

    init(directory: URL) { self.directory = directory }

    func applicationDidFinishLaunching(_ notification: Notification) {
        originalWidth = Settings.shared.lineWidth
        originalFont = Settings.shared.fontSize
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try showImageEditor()
            try showVideoCanvas()
            windows.first?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) { NSApp.terminate(nil) }
        } catch {
            try? Data(error.localizedDescription.utf8).write(to: directory.appendingPathComponent("failure.txt"))
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Settings.shared.lineWidth = originalWidth
        Settings.shared.fontSize = originalFont
    }

    private func showImageEditor() throws {
        Settings.shared.lineWidth = 3
        Settings.shared.fontSize = 18
        let source = EditorImageSource(image: try image(), scale: 1)
        let view = OverlayView(source: source)
        view.delegate = self
        let window = ClipboardEditorWindow(editor: view)
        window.title = "Slightshot · annotation size review · automated fixture"
        window.appearance = NSAppearance(named: .darkAqua)
        windows.append(window)
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        try choose(.arrow, in: window.contentView!)
        try draw(view, from: CGPoint(x: 180, y: 120), to: CGPoint(x: 560, y: 120))
        try snapshot(window.contentView!, name: "mac-before")
        try scroll(view, at: CGPoint(x: 590, y: 270), ticks: 6)
        try draw(view, from: CGPoint(x: 180, y: 270), to: CGPoint(x: 560, y: 270))
        try scroll(view, at: CGPoint(x: 590, y: 270), ticks: 1)
        try scroll(view, at: CGPoint(x: 590, y: 270), ticks: -1)
        try snapshot(window.contentView!, name: "mac-increased")
        try scroll(view, at: CGPoint(x: 590, y: 420), ticks: -7)
        try draw(view, from: CGPoint(x: 180, y: 420), to: CGPoint(x: 560, y: 420))
        try scroll(view, at: CGPoint(x: 590, y: 420), ticks: 1)
        try scroll(view, at: CGPoint(x: 590, y: 420), ticks: -1)
        try snapshot(window.contentView!, name: "mac-decreased")
        try choose(.text, in: window.contentView!)
        try scroll(view, at: CGPoint(x: 400, y: 500), ticks: 4)
        view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 180, y: 500), in: view))
        guard let entry = view.subviews.compactMap({ $0 as? TextEntryView }).first else {
            throw CaptureError.failed("Missing text draft")
        }
        entry.string = "Scroll-sized text"
        view.commitTextEntry()
        try scroll(view, at: CGPoint(x: 480, y: 500), ticks: 1)
        try scroll(view, at: CGPoint(x: 480, y: 500), ticks: -1)
        try snapshot(window.contentView!, name: "mac-text")
        try choose(.arrow, in: window.contentView!)
    }

    private func showVideoCanvas() throws {
        let view = VideoCanvasView(sourceSize: CGSize(width: 800, height: 600))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Slightshot · video canvas scroll fixture"
        window.isReleasedWhenClosed = false
        window.contentView = view
        windows.append(window)
        window.center()
        window.makeKeyAndOrderFront(nil)
        view.tool = .arrow
        view.lineWidth = 3
        view.onCommit = { annotation in
            view.annotations.append(VideoAnnotation(annotation: annotation, start: 0, end: 5))
        }
        view.showFrame(try image(), at: 0)
        try scroll(view, at: CGPoint(x: 580, y: 270), ticks: 6)
        view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 180, y: 270), in: view))
        view.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 560, y: 270), in: view))
        view.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 560, y: 270), in: view))
        try scroll(view, at: CGPoint(x: 580, y: 270), ticks: 1)
        try scroll(view, at: CGPoint(x: 580, y: 270), ticks: -1)
        try snapshot(view, name: "mac-video")
        view.onCommit = nil
    }

    private func image() throws -> CGImage {
        guard let context = CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureError.noDisplays }
        context.translateBy(x: 0, y: 600)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        NSColor(srgbRed: 0.94, green: 0.95, blue: 0.97, alpha: 1).setFill()
        CGRect(x: 0, y: 0, width: 800, height: 600).fill()
        let labels = [("Scroll to resize annotations", 45), ("Before · 3 pt", 90),
                      ("Scroll up · 9 pt", 240), ("Scroll down · 2 pt", 390), ("Text · 26 pt", 475)]
        for (label, y) in labels {
            (label as NSString).draw(at: CGPoint(x: 60, y: y), withAttributes: [
                .font: NSFont.systemFont(ofSize: y == 45 ? 24 : 16, weight: .semibold),
                .foregroundColor: NSColor.darkGray,
            ])
        }
        guard let image = context.makeImage() else { throw CaptureError.noDisplays }
        return image
    }

    private func choose(_ tool: Tool, in view: NSView) throws {
        guard let button = descendants(view).compactMap({ $0 as? ToolbarButton })
            .first(where: { $0.accessibilityLabel() == tool.title }) else {
            throw CaptureError.failed("Missing tool")
        }
        if !button.isSelectedItem { button.performClick(nil) }
    }

    private func draw(_ view: OverlayView, from start: CGPoint, to end: CGPoint) throws {
        view.mouseDown(with: try mouse(.leftMouseDown, at: start, in: view))
        view.mouseDragged(with: try mouse(.leftMouseDragged, at: end, in: view))
        view.mouseUp(with: try mouse(.leftMouseUp, at: end, in: view))
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in view: NSView) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: view.window!.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1) else { throw CaptureError.failed("Missing mouse event") }
        return event
    }

    private func scroll(_ view: NSView, at point: CGPoint, ticks: Int32) throws {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                               wheel1: ticks, wheel2: 0, wheel3: 0) else { throw CaptureError.noDisplays }
        let screen = view.window!.convertPoint(toScreen: view.convert(point, to: nil))
        cg.location = CGPoint(x: screen.x, y: NSScreen.screens[0].frame.height - screen.y)
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(view.window!.windowNumber))
        guard let event = NSEvent(cgEvent: cg) else { throw CaptureError.failed("Missing scroll event") }
        view.scrollWheel(with: event)
    }

    private func snapshot(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CaptureError.noDisplays }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CaptureError.noDisplays }
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    func overlayDidCancel(_ view: OverlayView) { NSApp.terminate(nil) }
    func overlayDidTakeOver(_ view: OverlayView) {}
    func overlay(_ view: OverlayView, didComplete action: CaptureAction, image: CGImage) {}
    func overlay(_ view: OverlayView, didRequestRecording selection: CGRect) {}
}
