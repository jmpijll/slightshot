import AppKit
import Testing
@testable import Slightshot

@MainActor
struct VideoRasterScaleTests {
    @Test func fit4KStepGestureKeepsScreenshotStampSize() throws {
        let canvas = VideoCanvasView(sourceSize: CGSize(width: 3840, height: 2160))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 960, height: 540),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        canvas.frame = CGRect(x: 0, y: 0, width: 960, height: 540)
        let preview = try pattern()
        canvas.showFrame(preview, at: 0.5)
        canvas.tool = .step
        canvas.color = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        var committed: Annotation?
        canvas.onCommit = { committed = $0 }
        defer { window.close() }
        let point = CGPoint(x: 500, y: 300)
        canvas.mouseDown(with: try mouse(.leftMouseDown, point: point, in: canvas))
        canvas.mouseUp(with: try mouse(.leftMouseUp, point: point, in: canvas))
        let mark = try #require(committed)
        let image = try #require(VideoFrameRenderer.render(image: preview, at: 0.5,
            annotations: [VideoAnnotation(annotation: mark, start: 0, end: 1)], scale: 0.25))
        let screenshot = try #require(Renderer.flatten(image: preview, scale: 1,
            selection: CGRect(x: 0, y: 0, width: 960, height: 540),
            annotations: [Annotation(shape: .step(number: 1, center: point), color: canvas.color, lineWidth: 4)]))
        let actual = redStampBounds(image)
        let expected = redStampBounds(screenshot)
        #expect(actual.width == expected.width, "A numbered stamp should keep screenshot size at 4K fit.")
        #expect(actual.height == expected.height)
    }

    private func redStampBounds(_ image: CGImage) -> CGRect {
        let data = bytes(image)
        var left = 960, right = 0, top = 540, bottom = 0
        for y in 270..<330 {
            for x in 470..<530 {
                let offset = y * image.bytesPerRow + x * 4
                if data[offset + 2] > 180 && data[offset + 1] < 100 && data[offset] < 100 {
                    left = min(left, x); right = max(right, x)
                    top = min(top, y); bottom = max(bottom, y)
                }
            }
        }
        return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }

    @Test(arguments: [Tool.blur, .pixelate])
    func prepared4KFramesKeepPreviewStrengthAndTimedRange(tool: Tool) throws {
        let size = CGSize(width: 3840, height: 2160)
        let context = try #require(VideoFrameRenderer.makeContext(size: size))
        context.interpolationQuality = .none
        context.draw(try pattern(), in: CGRect(origin: .zero, size: size))
        let source = try #require(context.makeImage())
        let rect = CGRect(x: 400, y: 400, width: 800, height: 600)
        let mark = Annotation(shape: tool == .blur ? .blur(rect) : .pixelate(rect), color: .red,
                              lineWidth: 16, rasterScale: 4)
        let values = [VideoAnnotation(annotation: mark, start: 0.25, end: 0.75)]
        let prepared = try VideoFrameRenderer.prepare(values, size: size, duration: 1)
        for time in [0.24, 0.25, 0.5, 0.75] {
            let preview = try #require(VideoFrameRenderer.render(image: source, at: time, annotations: values))
            let export = try VideoFrameRenderer.render(image: source, at: time, prepared: prepared, context: context)
            let expected = bytes(preview)
            let actual = bytes(export)
            // Sample this grayscale frame every 32 pixels, including hundreds
            // inside the mask. Check the half-open boundaries without logging
            // a full 4K buffer or blocking the main actor with millions of closures.
            let matches = expected.count == actual.count && stride(from: 0, to: expected.count, by: 128).allSatisfy {
                abs(Int(expected[$0]) - Int(actual[$0])) <= 2
            }
            #expect(matches, "Prepared 4K export must preserve the preview's effect strength at \(time)s.")
        }
    }

    @Test(arguments: [Tool.blur, .pixelate])
    func fitVideoPrivacyGestureMatchesScreenshotStrength(tool: Tool) throws {
        let preview = try pattern()
        let canvas = VideoCanvasView(sourceSize: CGSize(width: 3840, height: 2160))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 960, height: 540),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        canvas.frame = CGRect(x: 0, y: 0, width: 960, height: 540)
        canvas.showFrame(preview, at: 0.5)
        canvas.tool = tool
        var committed: Annotation?
        canvas.onCommit = { committed = $0 }
        defer { window.close() }

        let first = CGPoint(x: 100, y: 100)
        let last = CGPoint(x: 300, y: 250)
        canvas.mouseDown(with: try mouse(.leftMouseDown, point: first, in: canvas))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, point: last, in: canvas))
        canvas.mouseUp(with: try mouse(.leftMouseUp, point: last, in: canvas))
        let mark = try #require(committed)
        let actual = try #require(VideoFrameRenderer.render(image: preview, at: 0.5,
            annotations: [VideoAnnotation(annotation: mark, start: 0, end: 1)], scale: 0.25))
        let rect = CGRect(x: 100, y: 100, width: 200, height: 150)
        let expectedMark = Annotation(shape: tool == .blur ? .blur(rect) : .pixelate(rect),
                                      color: .red, lineWidth: 4)
        let expected = try #require(Renderer.flatten(image: preview, scale: 1,
            selection: CGRect(x: 0, y: 0, width: 960, height: 540), annotations: [expectedMark]))
        let matchesScreenshot = bytes(actual).elementsEqual(bytes(expected))
        #expect(matchesScreenshot,
                "A privacy rectangle drawn at the same displayed size must have screenshot strength at 4K fit.")

        // Resizing after creation must not silently weaken the saved mark.
        canvas.frame = CGRect(x: 0, y: 0, width: 480, height: 270)
        let resized = try #require(VideoFrameRenderer.render(image: preview, at: 0.5,
            annotations: [VideoAnnotation(annotation: mark, start: 0, end: 1)], scale: 0.25))
        let matchesBeforeResize = bytes(resized).elementsEqual(bytes(actual))
        #expect(matchesBeforeResize)
    }

    private func mouse(_ type: NSEvent.EventType, point: CGPoint, in view: NSView) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                                       timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func pattern() throws -> CGImage {
        let context = try #require(VideoFrameRenderer.makeContext(size: CGSize(width: 960, height: 540)))
        context.setFillColor(CGColor(gray: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 960, height: 540))
        for x in stride(from: 80, to: 320, by: 4) {
            context.setFillColor(CGColor(gray: (x / 4).isMultiple(of: 2) ? 0 : 1, alpha: 1))
            context.fill(CGRect(x: x, y: 270, width: 4, height: 200))
        }
        return try #require(context.makeImage())
    }

    private func bytes(_ image: CGImage) -> [UInt8] {
        guard let data = image.dataProvider?.data else { return [] }
        return Array(UnsafeBufferPointer(start: CFDataGetBytePtr(data), count: CFDataGetLength(data)))
    }
}
