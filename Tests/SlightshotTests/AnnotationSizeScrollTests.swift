import AppKit
import Testing
@testable import Slightshot

@MainActor
struct AnnotationSizeScrollTests {
    @Test func wheelChangesWidthAndTextWithinExistingLimits() {
        var scroll = AnnotationSizeScroll()
        #expect(scroll.adjust(tool: .arrow, width: 3, fontSize: 18, delta: 1)?.value == 4)
        #expect(scroll.adjust(tool: .pen, width: 3, fontSize: 18, delta: -1)?.value == 2)
        #expect(scroll.adjust(tool: .marker, width: 12, fontSize: 18, delta: 100)?.value == 12)
        #expect(scroll.adjust(tool: .line, width: 1, fontSize: 18, delta: -100)?.value == 1)
        #expect(scroll.adjust(tool: .text, width: 3, fontSize: 18, delta: 1)?.value == 20)
        #expect(scroll.adjust(tool: .text, width: 3, fontSize: 48, delta: 10)?.value == 48)
        #expect(scroll.adjust(tool: .text, width: 3, fontSize: 10, delta: -10)?.value == 10)
        for tool in [Tool.blur, .pixelate, .step] {
            #expect(scroll.adjust(tool: tool, width: 3, fontSize: 18, delta: 1) == nil)
        }
        #expect(scroll.adjust(tool: .arrow, width: 3, fontSize: 18, delta: 0) == nil)
    }

    @Test func preciseScrollingAccumulatesAndResetsAcrossTools() {
        var scroll = AnnotationSizeScroll()
        #expect(scroll.adjust(tool: .arrow, width: 3, fontSize: 18, delta: 3, precise: true) == nil)
        #expect(scroll.adjust(tool: .arrow, width: 3, fontSize: 18, delta: 5, precise: true)?.value == 4)
        #expect(scroll.adjust(tool: .arrow, width: 3, fontSize: 18, delta: 7, precise: true) == nil)
        #expect(scroll.adjust(tool: .text, width: 3, fontSize: 18, delta: 1, precise: true) == nil)
        #expect(scroll.adjust(tool: .text, width: 3, fontSize: 18, delta: 7, precise: true)?.value == 20)
        scroll.reset()
        #expect(scroll.adjust(tool: .text, width: 3, fontSize: 18, delta: 1, precise: true) == nil)
    }

    @Test func nativeOverlayWheelChangesNewMarksKeepsHistoryAndSyncsPalette() throws {
        let context = try #require(CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let source = EditorImageSource(image: try #require(context.makeImage()), scale: 1)
        let view = OverlayView(source: source)
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        view.selectAll()
        let canvas = try #require(view.subviews.compactMap { $0 as? CanvasView }.first)
        let savedWidth = Settings.shared.lineWidth
        let savedFont = Settings.shared.fontSize
        defer { Settings.shared.lineWidth = savedWidth; Settings.shared.fontSize = savedFont }
        view.toolbarDidChangeLineWidth(3)
        try choose(.arrow, in: view)
        try draw(in: view, from: CGPoint(x: 80, y: 90), to: CGPoint(x: 260, y: 90))
        let first = try #require(canvas.annotations.first)
        view.undo()
        let swatch = try #require(descendants(view).compactMap { $0 as? ColorSwatchButton }.first)
        swatch.performClick(nil)
        view.scrollWheel(with: try wheel(in: view, delta: 1))
        #expect(Settings.shared.lineWidth == 4)
        let slider = try #require(descendants(view).compactMap { $0 as? NSSlider }.first)
        #expect(slider.doubleValue == 4)
        view.redo()
        #expect(canvas.annotations.first?.lineWidth == first.lineWidth)
        try draw(in: view, from: CGPoint(x: 80, y: 150), to: CGPoint(x: 260, y: 150))
        #expect(canvas.annotations.last?.lineWidth == 4)
        #expect(descendants(view).contains { $0.accessibilityLabel() == "Thickness 4 pt" })
        try choose(.text, in: view)
        view.scrollWheel(with: try wheel(in: view, delta: 1))
        try view.mouseDown(with: mouse(.leftMouseDown, point: CGPoint(x: 100, y: 220), in: view))
        let entry = try #require(view.subviews.compactMap { $0 as? TextEntryView }.first)
        let draftSize = entry.font?.pointSize
        let sizeBefore = Settings.shared.fontSize
        view.scrollWheel(with: try wheel(in: view, delta: 1))
        #expect(Settings.shared.fontSize == sizeBefore)
        #expect(entry.font?.pointSize == draftSize)
        entry.string = "Sized text"
        view.commitTextEntry()
        #expect(canvas.annotations.last?.fontSize == CGFloat(sizeBefore))
    }

    private func choose(_ tool: Tool, in view: NSView) throws {
        let button = try #require(descendants(view).compactMap { $0 as? ToolbarButton }
            .first { $0.accessibilityLabel() == tool.title })
        if !button.isSelectedItem { button.performClick(nil) }
    }

    @Test func videoWheelUsesDisplaySizeAtZoomAndSkipsFixedTools() throws {
        let context = try #require(CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let view = VideoCanvasView(sourceSize: CGSize(width: 640, height: 480))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        view.tool = .arrow
        view.lineWidth = 3
        view.showFrame(try #require(context.makeImage()), at: 0)
        var committed: Annotation?
        var sliderWidth: CGFloat?
        view.onCommit = { committed = $0 }
        view.onWidthChange = { sliderWidth = $0 }
        view.scrollWheel(with: try wheel(in: view, delta: 1))
        #expect(view.lineWidth == 4)
        #expect(sliderWidth == 4)
        view.mouseDown(with: try mouse(.leftMouseDown, point: CGPoint(x: 50, y: 60), in: view))
        view.mouseDragged(with: try mouse(.leftMouseDragged, point: CGPoint(x: 150, y: 60), in: view))
        view.mouseUp(with: try mouse(.leftMouseUp, point: CGPoint(x: 150, y: 60), in: view))
        #expect(committed?.lineWidth == 8)
        view.tool = .text
        view.scrollWheel(with: try wheel(in: view, delta: 1))
        #expect(view.fontSize == 26)
        for tool in [Tool.blur, .pixelate, .step] {
            view.tool = tool
            view.scrollWheel(with: try wheel(in: view, delta: 1))
            #expect(view.lineWidth == 4)
            #expect(view.fontSize == 26)
        }
    }

    private func draw(in view: OverlayView, from start: CGPoint, to end: CGPoint) throws {
        view.mouseDown(with: try mouse(.leftMouseDown, point: start, in: view))
        view.mouseDragged(with: try mouse(.leftMouseDragged, point: end, in: view))
        view.mouseUp(with: try mouse(.leftMouseUp, point: end, in: view))
    }

    private func mouse(_ type: NSEvent.EventType, point: CGPoint, in view: NSView) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: view.window!.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func wheel(in view: NSView, delta: Int32) throws -> NSEvent {
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                     wheel1: delta, wheel2: 0, wheel3: 0))
        let screenPoint = view.window!.convertPoint(toScreen: view.convert(CGPoint(x: 200, y: 200), to: nil))
        cg.location = CGPoint(x: screenPoint.x, y: NSScreen.screens[0].frame.height - screenPoint.y)
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(view.window!.windowNumber))
        let event = try #require(NSEvent(cgEvent: cg))
        return event
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
