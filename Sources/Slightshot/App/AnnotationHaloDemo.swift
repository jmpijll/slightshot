import AppKit

/// A bounded review fixture. Synthetic input drives the real editor and scroll handler.
final class AnnotationHaloDemo: NSObject, NSApplicationDelegate, OverlayViewDelegate {
    private let directory: URL
    private var window: NSWindow?
    private var editor: OverlayView?
    private let pointer = NSImageView()
    private var task: Task<Void, Never>?
    private var originalWidth: Double = 3
    private var originalFont: Double = 18
    private var originalColor: NSColor = .systemRed

    init(directory: URL) { self.directory = directory }

    func applicationDidFinishLaunching(_ notification: Notification) {
        originalWidth = Settings.shared.lineWidth
        originalFont = Settings.shared.fontSize
        originalColor = Settings.shared.annotationColor
        task = Task {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try await demonstrate()
            } catch {
                try? Data(error.localizedDescription.utf8).write(to: directory.appendingPathComponent("failure.txt"))
            }
            NSApp.terminate(nil)
        }
    }

    private func demonstrate() async throws {
        let view = try showEditor()
        guard let window else { throw CaptureError.noDisplays }
        try await Task.sleep(for: .milliseconds(600))
        let movie = directory.appendingPathComponent("cursor-halo-preview.mp4")
        let recorder = NativeWindowDemoRecorder(destination: movie)
        try await recorder.start(window: window)
        do {
            try await Task.sleep(for: .milliseconds(800))
            try beginArrow(view, at: 140)
            for width in 2...12 {
                try scroll(view, ticks: 1, at: CGPoint(x: 530, y: 140))
                if width == 9 { try snapshot(view, name: "cursor-halo-native-control") }
                try await Task.sleep(for: .milliseconds(220))
            }
            try releaseArrow(view, at: 140)
            try await Task.sleep(for: .milliseconds(1700))
            try beginArrow(view, at: 285)
            for _ in 1...11 {
                try scroll(view, ticks: -1, at: CGPoint(x: 530, y: 285))
                try await Task.sleep(for: .milliseconds(220))
            }
            try releaseArrow(view, at: 285)
            try await Task.sleep(for: .milliseconds(1700))
            try choose(.text, in: view)
            for _ in 1...9 {
                try scroll(view, ticks: 2, at: CGPoint(x: 480, y: 430))
                try await Task.sleep(for: .milliseconds(220))
            }
            view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 190, y: 415), in: view))
            guard let entry = view.subviews.compactMap({ $0 as? TextEntryView }).first else {
                throw CaptureError.failed("Missing native text entry")
            }
            entry.string = "Aa"
            view.commitTextEntry()
            try scroll(view, ticks: -1, at: CGPoint(x: 480, y: 430))
            try await Task.sleep(for: .milliseconds(2000))
            _ = try await recorder.stop()
            try writeReport(view)
        } catch {
            _ = try? await recorder.stop()
            throw error
        }
    }

    private func showEditor() throws -> OverlayView {
        Settings.shared.lineWidth = 1
        Settings.shared.fontSize = 10
        Settings.shared.annotationColor = NSColor(hex: "#FF3B30")!
        guard let context = CGContext(data: nil, width: 800, height: 560, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureError.noDisplays }
        context.setFillColor(CGColor(red: 0.94, green: 0.95, blue: 0.97, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 560))
        guard let image = context.makeImage() else { throw CaptureError.noDisplays }
        let view = OverlayView(source: EditorImageSource(image: image, scale: 1))
        view.delegate = self
        let window = ClipboardEditorWindow(editor: view)
        window.title = "Slightshot · cursorhalo"
        window.appearance = NSAppearance(named: .darkAqua)
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        self.editor = view
        pointer.image = NSCursor.crosshair.image
        pointer.imageScaling = .scaleNone
        pointer.setAccessibilityElement(false)
        try choose(.arrow, in: view)
        return view
    }

    private func beginArrow(_ view: OverlayView, at y: CGFloat) throws {
        view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 150, y: y), in: view))
        view.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 530, y: y), in: view))
    }

    private func releaseArrow(_ view: OverlayView, at y: CGFloat) throws {
        view.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 530, y: y), in: view))
    }

    private func scroll(_ view: OverlayView, ticks: Int32, at point: CGPoint) throws {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                              wheel1: ticks, wheel2: 0, wheel3: 0), let event = NSEvent(cgEvent: cg),
              view.handleSizeScroll(event, at: point) else {
            throw CaptureError.failed("Demo scroll was not handled")
        }
        showPointer(at: point, in: view)
    }

    private func showPointer(at point: CGPoint, in view: OverlayView) {
        guard let host = view.window?.contentView else { return }
        let center = view.convert(point, to: host)
        let size = NSCursor.crosshair.image.size
        pointer.frame = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                               width: size.width, height: size.height)
        host.addSubview(pointer, positioned: .above, relativeTo: nil)
    }

    private func choose(_ tool: Tool, in view: OverlayView) throws {
        guard let host = view.window?.contentView,
              let button = descendants(host).compactMap({ $0 as? ToolbarButton })
                .first(where: { $0.accessibilityLabel() == tool.title }) else {
            throw CaptureError.failed("Missing demo tool")
        }
        if !button.isSelectedItem { button.performClick(nil) }
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in view: NSView) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: view.window!.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1) else { throw CaptureError.failed("Missing demo mouse event") }
        return event
    }

    private func snapshot(_ view: NSView, name: String) throws {
        guard let host = view.window?.contentView,
              let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CaptureError.noDisplays }
        host.layoutSubtreeIfNeeded()
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CaptureError.noDisplays }
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }

    private var sourceCommit: String {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--review-source-commit"), args.indices.contains(index + 1) else {
            return "unspecified"
        }
        return args[index + 1]
    }

    private func writeReport(_ view: OverlayView) throws {
        let marks = view.canvas.annotations
        guard marks.count == 3, marks[0].lineWidth == 12, marks[1].lineWidth == 1, marks[2].fontSize == 46 else {
            throw CaptureError.failed("Demo annotation validation failed")
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "platform": "macOS 27 / AppKit",
            "sourceCommit": sourceCommit,
            "variant": "Production cursor halo, with a native crosshair fixture marking injected pointer positions.",
            "capture": "ScreenCaptureKit recording of the live native editor window only; no desktop pixels or audio.",
            "interaction": "Automated mouse gestures and production scroll-handler calls on a synthetic 800×560 image. "
                + "The visible native crosshair marks injected pointer coordinates; it is part of the fixture.",
            "checks": ["Arrow grows from 1 to 12 pt", "Second arrow shrinks from 12 to 1 pt",
                       "Text grows from 10 to 46 pt", "Halo grows and shrinks around the pointer, with no visible text",
                       "Indicator automatically disappears after scrolling stops"],
        ], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("validation.json"))
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    func applicationWillTerminate(_ notification: Notification) {
        Settings.shared.lineWidth = originalWidth
        Settings.shared.fontSize = originalFont
        Settings.shared.annotationColor = originalColor
    }
    func overlayDidCancel(_ view: OverlayView) { task?.cancel() }
    func overlayDidTakeOver(_ view: OverlayView) {}
    func overlay(_ view: OverlayView, didComplete action: CaptureAction, image: CGImage) {}
    func overlay(_ view: OverlayView, didRequestRecording selection: CGRect) {}
}
