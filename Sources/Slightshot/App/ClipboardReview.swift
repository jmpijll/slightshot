import AppKit

/// Bounded native review fixture. It never captures a screen or requests permission.
enum ClipboardReview {
    static func run() {
        let app = NSApplication.shared
        let index = CommandLine.arguments.firstIndex(of: "--clipboard-review")!
        let directory = CommandLine.arguments[safe: index + 1].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("build/clipboard-review", isDirectory: true)
        let delegate = ClipboardReviewDelegate(directory: directory)
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// Memory-only snapshot; a changed external clipboard must never be overwritten.
final class ClipboardReviewPasteboard {
    private let board: NSPasteboard
    private let original: [NSPasteboardItem]
    private let originalCount: Int
    private var ownedCount: Int?

    init(board: NSPasteboard) {
        self.board = board
        originalCount = board.changeCount
        original = (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    var ownsCurrentContents: Bool { ownedCount == board.changeCount }

    func seed(_ png: Data) -> Bool {
        guard board.changeCount == originalCount else { return false }
        board.clearContents()
        board.setData(png, forType: .png)
        ownedCount = board.changeCount
        return true
    }

    func acceptReviewExport(_ png: Data, wasOwned: Bool) {
        guard wasOwned, board.data(forType: .png) == png else { return }
        ownedCount = board.changeCount
    }

    func restoreIfOwned() {
        guard ownsCurrentContents else { return }
        board.clearContents()
        if !original.isEmpty { board.writeObjects(original) }
        ownedCount = nil
    }
}

private final class ClipboardReviewDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private let directory: URL
    private var snapshot: ClipboardReviewPasteboard?
    private lazy var coordinator = OverlayCoordinator(output: { [weak self] action, image in
        let owned = self?.snapshot?.ownsCurrentContents == true
        let succeeded = OutputService.perform(action, image: image)
        if succeeded, let png = Renderer.encode(image, as: .png, quality: 1) {
            if action == .copy || ((action == .save || action == .saveAs) && Settings.shared.copyAfterSave) {
                self?.snapshot?.acceptReviewExport(png, wasOwned: owned)
            }
            self?.write(image, png: png, name: "clipboard-review-export")
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        return succeeded
    })

    init(directory: URL) { self.directory = directory }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItemController(onCaptureArea: {}, onSaveFullScreen: {}, onCopyFullScreen: {},
                                         onEditClipboard: { [weak self] in self?.coordinator.editImageFromClipboard() })
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
        let saved = ClipboardReviewPasteboard(board: .general)
        snapshot = saved
        guard saved.seed(png) else { NSApp.terminate(nil); return }
        write(image, png: png, name: "clipboard-review-source")
        coordinator.editImageFromClipboard()
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { NSApp.terminate(nil) }
    }

    func applicationWillTerminate(_ notification: Notification) { snapshot?.restoreIfOwned() }

    private func write(_ image: CGImage, png: Data, name: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
            let bitmap = NSBitmapImageRep(cgImage: image)
            let report: [String: Any] = [
                "source": "Native review fixture/output PNG; synthetic pixels only; no screen capture",
                "width": image.width, "height": image.height, "hasAlpha": bitmap.hasAlpha,
                "cornerAlpha": bitmap.colorAt(x: 0, y: 0)?.alphaComponent ?? -1,
            ]
            let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try json.write(to: directory.appendingPathComponent(name + ".json"), options: .atomic)
        } catch {
            Log.output.error("Clipboard review evidence write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
