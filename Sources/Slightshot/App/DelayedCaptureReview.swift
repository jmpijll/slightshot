import AppKit
import ScreenCaptureKit

/// Bounded review entry point, with no inbox, hotkeys or updater. The controls,
/// menu and countdown are production native UI; only the frozen source is
/// synthetic so the review never writes a user's desktop pixels into evidence.
final class DelayedCaptureReview: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var countdown: DelayedCapturePanel?
    private var expiry: Timer?
    private var evidenceTask: Task<Void, Never>?
    private let evidenceDirectory: URL?
    private let status = NSTextField(labelWithString: "Choose Capture Area in 5 Seconds to start.")
    private let overlays = OverlayCoordinator(output: { _, _ in false }, record: { _, _ in })
    private lazy var delayed = DelayedCaptureController(
        isBusy: { [weak self] in self?.overlays.isBusy ?? true },
        show: { [weak self] seconds in self?.showCountdown(seconds) },
        hide: { [weak self] in self?.closeCountdown() },
        capture: { [weak self] in self?.presentSource() }
    )

    init(evidenceDirectory: URL? = nil) { self.evidenceDirectory = evidenceDirectory }
    private lazy var menuController = StatusItemController(
        onCaptureArea: { [weak self] in self?.delayed.cancel(); self?.presentSource() },
        onSaveFullScreen: {}, onCopyFullScreen: {},
        onDelayedCapture: { [weak self] in self?.start() }, showInMenuBar: false
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 230),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Slightshot delayed capture review"
        window.isReleasedWhenClosed = false
        let heading = NSTextField(labelWithString: "Capture Area in 5 Seconds")
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        let detail = NSTextField(labelWithString:
            "Test the app's menu, countdown and area editor.\n"
                + "This fixture generates a test image when the countdown ends.")
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 2
        let menu = NSButton(title: "Show Capture Menu", target: self, action: #selector(showMenu))
        let start = NSButton(title: "Capture Area in 5 Seconds", target: self, action: #selector(start))
        let cancel = NSButton(title: "Cancel Countdown", target: self, action: #selector(cancel))
        let quit = NSButton(title: "Quit Review", target: self, action: #selector(quit))
        let buttons = NSStackView(views: [menu, start])
        buttons.spacing = 10
        let secondary = NSStackView(views: [cancel, quit])
        secondary.spacing = 10
        status.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let column = NSStackView(views: [heading, detail, buttons, secondary, status])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        column.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            column.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
        ])
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let timer = Timer(timeInterval: 300, repeats: false) { _ in
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        expiry = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func showMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menuController.menuNeedsUpdate(menu)
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }

    @objc private func start() {
        if delayed.start() { status.stringValue = "Countdown started. The focused window stays active." }
    }

    @objc private func cancel() {
        delayed.cancel()
        status.stringValue = "Countdown cancelled. No capture will open."
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func showCountdown(_ seconds: Int) {
        if countdown == nil {
            countdown = DelayedCapturePanel { [weak self] in self?.cancel() }
            countdown?.orderFrontRegardless()
            if let countdown { captureHUDEvidence(countdown) }
        }
        countdown?.update(seconds: seconds)
    }

    private func closeCountdown() {
        evidenceTask?.cancel()
        evidenceTask = nil
        countdown?.close()
        countdown = nil
    }

    private func captureHUDEvidence(_ panel: DelayedCapturePanel) {
        guard let directory = evidenceDirectory else { return }
        evidenceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                guard let self, self.delayed.isPending, self.countdown === panel else { return }
                let bitmap: NSBitmapImageRep
                let source: String
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(
                        false, onScreenWindowsOnly: true)
                    let windowID = UInt32(panel.windowNumber)
                    guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                        throw CaptureError.failed("Review HUD is not in shareable content")
                    }
                    let config = SCStreamConfiguration()
                    let scale = panel.screen?.backingScaleFactor ?? 1
                    config.width = Int(panel.frame.width * scale)
                    config.height = Int(panel.frame.height * scale)
                    config.showsCursor = false
                    config.ignoreShadowsSingleWindow = true
                    config.captureResolution = .best
                    let image = try await SCScreenshotManager.captureImage(
                        contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
                    bitmap = NSBitmapImageRep(cgImage: image)
                    source = "ScreenCaptureKit screenshot of the live production AppKit countdown window; "
                        + "no desktop pixels"
                } catch {
                    guard let view = panel.contentView,
                          let rendered = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw error }
                    view.cacheDisplay(in: view.bounds, to: rendered)
                    bitmap = rendered
                    source = "Native AppKit view rendering of the production countdown; ScreenCaptureKit unavailable: "
                        + error.localizedDescription
                }
                try Task.checkCancellation()
                guard self.delayed.isPending, self.countdown === panel,
                      let png = bitmap.representation(using: .png, properties: [:]) else { return }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try png.write(to: directory.appendingPathComponent("mac-hud.png"), options: .atomic)
                let report = try JSONSerialization.data(withJSONObject: ["source": source,
                    "window": "DelayedCapturePanel", "delaySeconds": 5], options: [.prettyPrinted, .sortedKeys])
                try report.write(to: directory.appendingPathComponent("mac-hud-source.json"), options: .atomic)
            } catch {
                if !(error is CancellationError) {
                    Log.app.error("HUD review evidence failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func presentSource() {
        guard !overlays.isBusy, let screen = NSScreen.main else { return }
        status.stringValue = "Test image ready. Drag to select an area."
        let image = NSImage(size: screen.frame.size)
        image.lockFocus()
        NSColor(calibratedRed: 0.14, green: 0.35, blue: 0.25, alpha: 1).setFill()
        CGRect(origin: .zero, size: screen.frame.size).fill()
        let text = "Synthetic review source\nGenerated when capture starts\n"
            + "Drag to select an area; Esc closes the real editor."
        (text as NSString).draw(at: CGPoint(x: 80, y: screen.frame.height - 200), withAttributes: [
            .font: NSFont.systemFont(ofSize: 28, weight: .medium), .foregroundColor: NSColor.white,
        ])
        image.unlockFocus()
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        overlays.present([CapturedDisplay(screen: screen, displayID: screen.displayID, image: source,
                                          scale: CGFloat(source.width) / screen.frame.width)])
    }

    func applicationWillTerminate(_ notification: Notification) {
        delayed.cancel()
        overlays.dismiss()
        expiry?.invalidate()
    }
}
