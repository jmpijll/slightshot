import AppKit

/// Bounded native review fixture. It never captures a screen or requests permission.
enum ClipboardReview {
    static func run() {
        let app = NSApplication.shared
        let delegate = ClipboardReviewDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

private final class ClipboardReviewDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItemController(onCaptureArea: {}, onSaveFullScreen: {}, onCopyFullScreen: {},
                                         onEditClipboard: { OverlayCoordinator.shared.editImageFromClipboard() })
        guard let context = CGContext(data: nil, width: 2003, height: 1001, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { NSApp.terminate(nil); return }
        context.setFillColor(NSColor(calibratedRed: 0.12, green: 0.28, blue: 0.62, alpha: 0.8).cgColor)
        context.fill(CGRect(x: 120, y: 140, width: 1750, height: 720))
        context.setFillColor(NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.65, alpha: 0.6).cgColor)
        context.fillEllipse(in: CGRect(x: 350, y: 250, width: 540, height: 540))
        guard let image = context.makeImage(), let png = Renderer.encode(image, as: .png, quality: 1) else {
            NSApp.terminate(nil); return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
        OverlayCoordinator.shared.editImageFromClipboard()
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { NSApp.terminate(nil) }
    }
}
