import AppKit
import Testing
@testable import Slightshot

@MainActor
struct ClipboardEditorTests {
    @Test func directImageRepresentationsPreservePixelsAndRejectFiles() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        #expect(ClipboardImage.read(from: board) == nil)
        board.setString("plain text", forType: .string)
        #expect(ClipboardImage.read(from: board) == nil)
        board.clearContents()
        board.setString("file:///tmp/clipboard-image.png", forType: .fileURL)
        #expect(ClipboardImage.read(from: board) == nil)
        let png = try fixture(width: 257, height: 129)
        let tiff = try fixture(width: 32, height: 16)
        board.clearContents()
        let pngData = try #require(Renderer.encode(png, as: .png, quality: 1))
        let tiffData = try #require(Renderer.encode(tiff, as: .tiff, quality: 1))
        board.setData(pngData, forType: .png)
        board.setData(tiffData, forType: .tiff)
        let decoded = try #require(ClipboardImage.read(from: board))
        #expect(decoded.width == 257 && decoded.height == 129)
        #expect(alpha(decoded, at: CGPoint(x: 0, y: 0)) == 0)
        #expect(alpha(decoded, at: CGPoint(x: 30, y: 30)) == 128)
        board.clearContents()
        board.setData(tiffData, forType: .tiff)
        #expect(ClipboardImage.read(from: board)?.width == 32)
    }

    @Test func fitAndCroppedExportsRetainOriginalResolutionAndAlpha() throws {
        let image = try fixture(width: 2003, height: 1001)
        let source = EditorImageSource.clipboard(image, fitting: CGSize(width: 600, height: 400))
        #expect(source.size.width == 600)
        #expect(source.size.height < 400)
        let full = try #require(Renderer.flatten(image: image, scale: source.scale,
                                                selection: source.bounds, annotations: []))
        #expect(full.width == 2003 && full.height == 1001)
        #expect(alpha(full, at: .zero) == 0)
        #expect(alpha(full, at: CGPoint(x: 30, y: 30)) == 128)
        let crop = CGRect(x: 20 / source.scale, y: 10 / source.scale,
                          width: 400 / source.scale, height: 300 / source.scale)
        let cropped = try #require(Renderer.flatten(image: image, scale: source.scale,
                                                   selection: crop, annotations: []))
        #expect(cropped.width == 400 && cropped.height == 300)
        #expect(alpha(cropped, at: CGPoint(x: 10, y: 20)) == 128)
    }

    @Test func smallPortraitAndExtremeWideImagesKeepEveryPixel() throws {
        for size in [(1, 1), (9, 3001), (3001, 1)] {
            let image = try fixture(width: size.0, height: size.1)
            let source = EditorImageSource.clipboard(image, fitting: CGSize(width: 600, height: 400))
            let export = try #require(Renderer.flatten(image: image, scale: source.scale,
                selection: source.bounds, annotations: []))
            #expect(export.width == size.0 && export.height == size.1)
        }
    }

    @Test func clipboardSessionRetainsEditorOnFailureAndReleasesOwnershipOnClose() async throws {
        _ = NSApplication.shared
        let presentation = ClipboardTestPresentation()
        let image = try fixture(width: 2003, height: 1001)
        var coordinator: OverlayCoordinator!
        var deliveries = 0
        var captures = 0
        var recordings = 0
        coordinator = OverlayCoordinator(clipboardPresentation: presentation, output: { _, exported in
            deliveries += 1
            #expect(exported.width == 2003 && exported.height == 1001)
            #expect(alpha(exported, at: .zero) == 0)
            #expect(coordinator.isBusy)
            #expect(!presentation.visible)
            coordinator.presentClipboardImage(image)
            coordinator.beginRegionCapture()
            presentation.view?.toolbarDidRequestRecording()
            presentation.closeNatively()
            return deliveries > 1
        }, record: { _, _ in recordings += 1 }, captureAll: {
            captures += 1; return []
        })
        coordinator.presentClipboardImage(image)
        let view = try #require(presentation.view)
        // Hidden native test windows avoid displaying UI on the shared desktop.
        view.selectAll()
        #expect(view.capturedDisplay == nil)
        #expect(!presentation.buttons.contains { $0.toolTip == "Record selected area" })
        view.toolbarDidRequest(.saveAs)
        await Task.yield()
        #expect(captures == 0 && recordings == 0 && deliveries == 1)
        #expect(coordinator.isBusy && presentation.visible)
        #expect(presentation.view === view)
        view.toolbarDidRequest(.copy)
        #expect(deliveries == 2 && !coordinator.isBusy && presentation.view == nil)
        coordinator.presentClipboardImage(image)
        presentation.closeNatively()
        #expect(!coordinator.isBusy && presentation.view == nil)
    }

    private func fixture(width: Int, height: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 10..<max(10, min(height, 80)) {
            for x in 10..<max(10, min(width, 80)) {
                let offset = (y * width + x) * 4
                bytes[offset] = 128; bytes[offset + 3] = 128
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func alpha(_ image: CGImage, at point: CGPoint) -> Int {
        let color = NSBitmapImageRep(cgImage: image).colorAt(x: Int(point.x), y: Int(point.y))
        return Int(((color?.alphaComponent ?? -1) * 255).rounded())
    }

}

@MainActor
private final class ClipboardTestPresentation: OverlayPresentation {
    var view: OverlayView?
    var visible = false
    private var window: ClipboardEditorWindow?
    var buttons: [NSButton] { window?.contentView.map(descendants) ?? [] }
    private func descendants(_ view: NSView) -> [NSButton] {
        view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? descendants($0) }
    }
    func closeNatively() { window?.performClose(nil) }
    func show(_ views: [OverlayView], focused: OverlayView?) {
        view = views.first
        if window == nil, let view {
            let native = ClipboardEditorWindow(editor: view)
            native.onClose = { [weak view] in view?.toolbarDidRequestClose() }
            window = native
        }
        visible = true
    }
    func focus(_ view: OverlayView) { }
    func hide() { visible = false }
    func close() { window?.delegate = nil; window?.close(); window = nil; view = nil; visible = false }
}
