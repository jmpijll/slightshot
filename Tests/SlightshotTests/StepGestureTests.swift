import AppKit
import Testing
@testable import Slightshot

@MainActor
struct StepGestureTests {
    @Test func aTapAndDraggedGestureEachStampOnceAndRapidClicksKeepEditing() throws {
        let source = try fixture()
        let screen = try #require(NSScreen.main)
        let view = OverlayView(display: CapturedDisplay(screen: screen, displayID: screen.displayID,
                                                       image: source, scale: 1))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 120, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = CGRect(x: 0, y: 0, width: 120, height: 100)
        let delegate = CaptureDelegate()
        view.delegate = delegate
        view.selectAll()
        let button = try #require(descendants(of: view).compactMap { $0 as? ToolbarButton }
            .first { $0.accessibilityLabel() == "Numbered steps" })
        button.performClick(nil)

        view.mouseDown(with: try mouse(.leftMouseDown, point: CGPoint(x: 36, y: 36), in: view))
        view.mouseUp(with: try mouse(.leftMouseUp, point: CGPoint(x: 36, y: 36), in: view))
        view.mouseDown(with: try mouse(.leftMouseDown, point: CGPoint(x: 80, y: 60), in: view, clicks: 2))
        for point in [CGPoint(x: 100, y: 80), CGPoint(x: 110, y: 90)] {
            view.mouseDragged(with: try mouse(.leftMouseDragged, point: point, in: view))
        }
        view.mouseUp(with: try mouse(.leftMouseUp, point: CGPoint(x: 110, y: 90), in: view, clicks: 2))
        #expect(delegate.images.isEmpty)
        view.keyDown(with: try copyEvent())
        let actual = try #require(delegate.images.last)
        let expected = try #require(Renderer.flatten(image: source, scale: 1, selection: view.bounds, annotations: [
            stamp(1, center: CGPoint(x: 36, y: 36)), stamp(2, center: CGPoint(x: 80, y: 60)),
        ]))
        #expect(bytes(actual).elementsEqual(bytes(expected)))
        view.undo()
        view.mouseDown(with: try mouse(.leftMouseDown, point: CGPoint(x: 80, y: 60), in: view))
        view.mouseUp(with: try mouse(.leftMouseUp, point: CGPoint(x: 80, y: 60), in: view))
        view.keyDown(with: try copyEvent())
        #expect(bytes(try #require(delegate.images.last)).elementsEqual(bytes(expected)))
        window.close()
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func mouse(_ type: NSEvent.EventType, point: CGPoint, in view: NSView, clicks: Int = 1) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                                       timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
                                       context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
    }

    private func copyEvent() throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                     timestamp: 0, windowNumber: 0, context: nil, characters: "c",
                                     charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
    }

    private func stamp(_ number: Int, center: CGPoint) -> Annotation {
        Annotation(shape: .step(number: number, center: center),
                   color: Settings.shared.annotationColor, lineWidth: Settings.shared.lineWidth)
    }

    private func fixture() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 120, height: 100, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 100))
        return try #require(context.makeImage())
    }

    private func bytes(_ image: CGImage) -> [UInt8] {
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = context.data else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
                                        count: image.width * image.height * 4))
    }

    private final class CaptureDelegate: OverlayViewDelegate {
        var images: [CGImage] = []
        func overlayDidCancel(_ view: OverlayView) {}
        func overlayDidTakeOver(_ view: OverlayView) {}
        func overlay(_ view: OverlayView, didComplete action: CaptureAction, image: CGImage) { images.append(image) }
        func overlay(_ view: OverlayView, didRequestRecording selection: CGRect) {}
    }
}
