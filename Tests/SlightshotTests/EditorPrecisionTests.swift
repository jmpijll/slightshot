import AppKit
import Testing
@testable import Slightshot

@MainActor
struct EditorPrecisionTests {
    @Test func aClickOutsideTheSelectionKeepsItsAnnotations() throws {
        let harness = try OverlayHarness()
        defer { harness.close() }
        harness.drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 50))
        try harness.choose("Pen")
        harness.drag(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 40, y: 30))
        let before = try harness.copy()

        harness.drag(from: CGPoint(x: 100, y: 80), to: CGPoint(x: 100, y: 80))
        harness.drag(from: CGPoint(x: 100, y: 80), to: CGPoint(x: 102, y: 81))

        #expect(harness.view.annotations.count == 1)
        let after = try harness.copy()
        #expect(after.width == 50 && after.height == 40)
        #expect(pixels(after) == pixels(before))
    }

    @Test func draggingOutsideTheSelectionStartsAFreshOne() throws {
        let harness = try OverlayHarness()
        defer { harness.close() }
        harness.drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 50))
        try harness.choose("Pen")
        harness.drag(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 40, y: 30))

        harness.drag(from: CGPoint(x: 70, y: 60), to: CGPoint(x: 100, y: 90))

        #expect(harness.view.annotations.isEmpty)
        let image = try harness.copy()
        #expect(image.width == 30 && image.height == 30)
    }

    @Test func shiftConstrainsARectangleToASquareAndALineTo45Degrees() throws {
        let harness = try OverlayHarness()
        defer { harness.close() }
        harness.view.selectAll()
        try harness.choose("Rectangle")
        harness.drag(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 60, y: 24), modifiers: .shift)
        try harness.choose("Line")
        harness.drag(from: CGPoint(x: 20, y: 60), to: CGPoint(x: 60, y: 64), modifiers: .shift)

        guard case .rectangle(let rect) = harness.view.annotations.first?.shape else {
            Issue.record("Expected a rectangle"); return
        }
        #expect(rect == CGRect(x: 20, y: 20, width: 40, height: 40))
        guard case .line(_, let end) = harness.view.annotations.last?.shape else {
            Issue.record("Expected a line"); return
        }
        #expect(end.y == 60)
    }

    @Test func shiftSquaresStayInsideTheSelection() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 50)
        #expect(CGRect(square: CGPoint(x: 10, y: 10), toward: CGPoint(x: 90, y: 20), within: bounds)
                == CGRect(x: 10, y: 10, width: 40, height: 40))
        #expect(CGRect(square: CGPoint(x: 50, y: 40), toward: CGPoint(x: 45, y: 0), within: bounds)
                == CGRect(x: 10, y: 0, width: 40, height: 40))
    }

    @Test func aPenTapLeavesADot() throws {
        let harness = try OverlayHarness()
        defer { harness.close() }
        harness.view.selectAll()
        for tool in ["Pen", "Marker"] {
            try harness.choose(tool)
            harness.drag(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 50, y: 50))
        }

        #expect(harness.view.annotations.count == 2)
        for annotation in harness.view.annotations {
            guard case .stroke(let points) = annotation.shape else { Issue.record("Expected a stroke"); continue }
            #expect(points == [CGPoint(x: 50, y: 50)])
        }
    }

    @Test(arguments: [(Tool.rectangle, true), (.pen, false), (.marker, false)])
    func videoEditorSquaresShiftRectanglesAndKeepsTaps(tool: Tool, shift: Bool) throws {
        let canvas = VideoCanvasView(sourceSize: CGSize(width: 320, height: 180))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 180),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        defer { window.close() }
        canvas.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        canvas.showFrame(try image(width: 320, height: 180), at: 0)
        canvas.tool = tool
        var committed: Annotation?
        canvas.onCommit = { committed = $0 }

        let start = CGPoint(x: 100, y: 50)
        let end = shift ? CGPoint(x: 160, y: 56) : start
        let flags: NSEvent.ModifierFlags = shift ? .shift : []
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: start, in: canvas, modifiers: flags))
        if shift { canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: end, in: canvas, modifiers: flags)) }
        canvas.mouseUp(with: try mouse(.leftMouseUp, at: end, in: canvas, modifiers: flags))

        let shape = try #require(committed?.shape)
        switch shape {
        case .rectangle(let rect): #expect(rect == CGRect(x: 100, y: 50, width: 60, height: 60))
        case .stroke(let points): #expect(points.allSatisfy { $0 == start })
        default: Issue.record("Unexpected \(shape)")
        }
    }

    @Test func pixelAlignmentRoundsEachEdgeToTheDeviceGrid() {
        let rect = CGRect(x: 10.5, y: 3.2, width: 20.3, height: 7.6)
        #expect(rect.pixelAligned(scale: 2) == CGRect(x: 10.5, y: 3, width: 20.5, height: 8))
        #expect(rect.pixelAligned == CGRect(x: 11, y: 3, width: 20, height: 8))
    }

    @Test func aHalfPointSelectionOnRetinaExportsTheOutlinedPixels() throws {
        let source = try image(width: 240, height: 200)
        let harness = try OverlayHarness(image: source, scale: 2)
        defer { harness.close() }
        harness.drag(from: CGPoint(x: 10.5, y: 10.5), to: CGPoint(x: 30.5, y: 20.5))

        let copied = try harness.copy()
        let expected = try #require(source.cropping(to: CGRect(x: 21, y: 21, width: 40, height: 20)))
        #expect(copied.width == 40 && copied.height == 20)
        #expect(pixels(copied) == pixels(expected))
    }

    @Test(arguments: [(CGPoint.zero, 0), (CGPoint(x: 19.5, y: 19.5), 19)])
    func theLoupeCentresOnTheTruePixelAtDisplayEdges(point: CGPoint, pixel: Int) throws {
        let source = try image(width: 20, height: 20)
        let loupe = MagnifierView(source: EditorImageSource(image: source, scale: 1))
        loupe.move(to: point)
        let rep = try #require(loupe.bitmapImageRepForCachingDisplay(in: loupe.bounds))
        loupe.cacheDisplay(in: loupe.bounds, to: rep)

        let zoom = CGFloat(rep.pixelsWide) / loupe.bounds.width
        let centre = MagnifierView.zoomSide / 2
        let colour = try #require(rep.colorAt(x: Int(centre * zoom), y: Int(centre * zoom))?.usingColorSpace(.sRGB))
        let expected = CGFloat(40 + pixel * 10) / 255
        #expect(abs(colour.redComponent - expected) < 0.02)
        #expect(abs(colour.greenComponent - expected) < 0.02)
    }
}

/// Pixel (x, y) is (40 + 10x, 40 + 10y, 200), clear of the dark tones colour matching crushes.
@MainActor
private func image(width: Int, height: Int) throws -> CGImage {
    var data = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let offset = (y * width + x) * 4
            data[offset] = UInt8((40 + x * 10) % 256)
            data[offset + 1] = UInt8((40 + y * 10) % 256)
            data[offset + 2] = 200
        }
    }
    let provider = try #require(CGDataProvider(data: Data(data) as CFData))
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: width * 4, space: space,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
}

@MainActor
private func pixels(_ image: CGImage) -> [UInt8] {
    guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: image.width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let data = context.data else { return [] }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
                                     count: image.width * image.height * 4))
}

@MainActor
private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in view: NSView,
                   modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: modifiers,
                                   timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
}

@MainActor
private final class OverlayHarness {
    let view: OverlayView
    private let window: NSWindow
    private let delegate = Recorder()

    init(image source: CGImage? = nil, scale: CGFloat = 1) throws {
        let screen = try #require(NSScreen.main)
        let source = try source ?? image(width: 120, height: 100)
        view = OverlayView(display: CapturedDisplay(screen: screen, displayID: screen.displayID,
                                                    image: source, scale: scale))
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 120, height: 100),
                          styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = CGRect(x: 0, y: 0, width: 120, height: 100)
        view.delegate = delegate
    }

    /// The toolbar restores the last tool across overlays, so leave none behind for other tests.
    func close() {
        view.toolbars.select(nil)
        window.close()
    }

    func choose(_ label: String) throws {
        guard view.toolbars.activeTool?.title != label else { return }
        let button = try #require(descendants(of: view).compactMap { $0 as? ToolbarButton }
            .first { $0.accessibilityLabel() == label })
        button.performClick(nil)
    }

    func drag(from start: CGPoint, to end: CGPoint, modifiers: NSEvent.ModifierFlags = []) {
        guard let down = try? mouse(.leftMouseDown, at: start, in: view, modifiers: modifiers),
              let moved = try? mouse(.leftMouseDragged, at: end, in: view, modifiers: modifiers),
              let up = try? mouse(.leftMouseUp, at: end, in: view, modifiers: modifiers) else { return }
        view.mouseDown(with: down)
        if start != end { view.mouseDragged(with: moved) }
        view.mouseUp(with: up)
    }

    func copy() throws -> CGImage {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                 timestamp: 0, windowNumber: 0, context: nil, characters: "c",
                                                 charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        delegate.images.removeAll()
        view.keyDown(with: event)
        return try #require(delegate.images.last)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private final class Recorder: OverlayViewDelegate {
        var images: [CGImage] = []
        func overlayDidCancel(_ view: OverlayView) {}
        func overlayDidTakeOver(_ view: OverlayView) {}
        func overlay(_ view: OverlayView, didComplete action: CaptureAction, image: CGImage) { images.append(image) }
        func overlay(_ view: OverlayView, didRequestRecording selection: CGRect) {}
    }
}
