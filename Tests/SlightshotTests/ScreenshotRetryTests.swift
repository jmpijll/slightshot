import AppKit
import Testing
@testable import Slightshot

@MainActor
struct ScreenshotRetryTests {
    @Test func cancellationAndWriteFailureKeepTheEditableSelectionForRetry() throws {
        let presentation = HiddenPresentation()
        var attempts: [CGImage] = []
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = OverlayCoordinator(presentation: presentation) { _, image in
            attempts.append(image)
            if attempts.count == 1 { return false } // Save panel cancellation.
            if attempts.count == 2 {
                // A real write failure, outside the editor and presentation boundary.
                do { try Data([1]).write(to: directory.appendingPathComponent("missing/file.png")) }
                catch { return false }
                return true
            }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                guard let data = Renderer.encode(image, as: .png, quality: 1) else { return false }
                try data.write(to: directory.appendingPathComponent("retried.png"))
                return true
            } catch { return false }
        }
        coordinator.present([try fixture()])
        let view = try #require(presentation.views.first)
        try drag(view, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 210, y: 110))
        try choose("Blur", in: view)
        try drag(view, from: CGPoint(x: 25, y: 25), to: CGPoint(x: 65, y: 65))
        try choose("Pixelate", in: view)
        try drag(view, from: CGPoint(x: 80, y: 25), to: CGPoint(x: 120, y: 65))
        try choose("Text", in: view)
        view.mouseDown(with: try mouse(.leftMouseDown, CGPoint(x: 30, y: 80), in: view))
        let entry = try #require(descendants(view).compactMap { $0 as? TextEntryView }.first)
        entry.string = "Retry me"

        view.toolbarDidRequest(.saveAs)
        #expect(coordinator.isActive)
        #expect(presentation.visible)
        #expect(presentation.focused === view)
        #expect(presentation.views.first === view)
        #expect(attempts[0].width == 200 && attempts[0].height == 100)
        #expect(shade(attempts[0], x: 4, y: 4) == 0) // Unedited frozen source.
        #expect((60...195).contains(shade(attempts[0], x: 30, y: 30))) // Blur.
        #expect((60...195).contains(shade(attempts[0], x: 85, y: 35))) // Pixelate.
        #expect(descendants(view).allSatisfy { !($0 is TextEntryView) })
        view.toolbarDidRequest(.save)
        #expect(coordinator.isActive)
        #expect(presentation.visible)
        #expect(bytes(attempts[0]) == bytes(attempts[1]))

        view.undo() // Text committed for the first export remains undoable.
        view.toolbarDidRequest(.saveAs)
        #expect(attempts.count == 3)
        #expect(bytes(attempts[2]) != bytes(attempts[1]))
        #expect(shade(attempts[2], x: 30, y: 30) == shade(attempts[0], x: 30, y: 30))
        #expect(shade(attempts[2], x: 85, y: 35) == shade(attempts[0], x: 85, y: 35))
        #expect(!coordinator.isBusy)
        #expect(presentation.views.isEmpty)
        let saved = try #require(NSBitmapImageRep(data: Data(contentsOf: directory.appendingPathComponent("retried.png"))))
        #expect(saved.pixelsWide == 200 && saved.pixelsHigh == 100)
    }

    @Test func modalOutputIgnoresDuplicateCaptureOutputRecordingAndClose() async throws {
        let presentation = HiddenPresentation()
        var coordinator: OverlayCoordinator!
        var deliveries = 0
        var recordings = 0
        var extraCaptures = 0
        let display = try fixture()
        let editor = EditorReference()
        coordinator = OverlayCoordinator(presentation: presentation, output: { _, _ in
            deliveries += 1
            #expect(coordinator.isBusy)
            #expect(!presentation.visible)
            guard deliveries == 1, let view = editor.view else { return false }
            view.toolbarDidRequest(.saveAs)
            coordinator.beginRegionCapture()
            coordinator.captureFullScreen(.copy)
            view.toolbarDidRequestRecording()
            view.toolbarDidRequestClose()
            #expect(coordinator.isActive)
            return false
        }, record: { _, _ in recordings += 1 }, captureAll: {
            extraCaptures += 1; return []
        }, captureActive: {
            extraCaptures += 1; return display
        })
        coordinator.present([display])
        let view = try #require(presentation.views.first)
        editor.view = view
        try drag(view, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 210, y: 110))
        view.toolbarDidRequest(.saveAs)
        await Task.yield()
        #expect(extraCaptures == 0)
        #expect(deliveries == 1)
        #expect(recordings == 0)
        #expect(coordinator.isActive)
        #expect(presentation.visible)
        view.cancelOperation(nil)
        #expect(!coordinator.isBusy)
        #expect(presentation.views.isEmpty)
    }

    private func fixture() throws -> CapturedDisplay {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main)
        var pixels = [UInt8](repeating: 255, count: 320 * 240 * 4)
        for y in 0..<240 {
            for x in 0..<320 {
                let offset = (y * 320 + x) * 4
                let shade: UInt8 = (x + y) % 2 == 0 ? 0 : 255
                pixels[offset] = shade; pixels[offset + 1] = shade; pixels[offset + 2] = shade
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(width: 320, height: 240, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 320 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return CapturedDisplay(screen: screen, displayID: 0, image: image, scale: 1)
    }

    private func mouse(_ type: NSEvent.EventType, _ point: CGPoint, in view: NSView) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func drag(_ view: OverlayView, from start: CGPoint, to end: CGPoint) throws {
        view.mouseDown(with: try mouse(.leftMouseDown, start, in: view))
        view.mouseDragged(with: try mouse(.leftMouseDragged, end, in: view))
        view.mouseUp(with: try mouse(.leftMouseUp, end, in: view))
    }

    private func choose(_ title: String, in view: NSView) throws {
        let button = try #require(descendants(view).compactMap { $0 as? NSButton }.first { $0.toolTip == title })
        button.performClick(nil)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func bytes(_ image: CGImage) -> Data? { image.dataProvider?.data as Data? }

    private func shade(_ image: CGImage, x: Int, y: Int) -> Int {
        let color = NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
        return Int(((color?.redComponent ?? -1) * 255).rounded())
    }
}

@MainActor
private final class HiddenPresentation: OverlayPresentation {
    private var windows: [NSWindow] = []
    var views: [OverlayView] = []
    var visible = false
    var focused: OverlayView?

    func show(_ views: [OverlayView], focused: OverlayView?) {
        if windows.isEmpty {
            self.views = views
            windows = views.map { view in
                let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: true)
                window.isReleasedWhenClosed = false
                window.contentView = view
                return window
            }
        }
        visible = true
        self.focused = focused
    }

    func focus(_ view: OverlayView) { focused = view }
    func hide() { visible = false }
    func close() {
        for window in windows { window.contentView = nil; window.close() }
        windows = []; views = []; visible = false; focused = nil
    }
}

@MainActor
private final class EditorReference {
    weak var view: OverlayView?
}
