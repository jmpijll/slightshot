import AppKit

/// Bounded review entry point, with no inbox, hotkeys or updater. The controls,
/// menu and countdown are production native UI; only the frozen source is
/// synthetic so the review never writes a user's desktop pixels into evidence.
final class DelayedCaptureReview: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var countdown: DelayedCapturePanel?
    private var expiry: Timer?
    private let status = NSTextField(labelWithString: "Ready — choose Capture Area in 5 Seconds")
    private let overlays = OverlayCoordinator(output: { _, _ in false }, record: { _, _ in })
    private lazy var delayed = DelayedCaptureController(
        isBusy: { [weak self] in self?.overlays.isBusy ?? true },
        show: { [weak self] seconds in self?.showCountdown(seconds) },
        hide: { [weak self] in self?.countdown?.close(); self?.countdown = nil },
        capture: { [weak self] in self?.presentSource() }
    )
    private lazy var menuController = StatusItemController(
        onCaptureArea: { [weak self] in self?.delayed.cancel(); self?.presentSource() },
        onSaveFullScreen: {}, onCopyFullScreen: {},
        onDelayedCapture: { [weak self] in self?.start() }, showInMenuBar: false
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 230),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Slightshot — Delayed Capture Native Review"
        window.isReleasedWhenClosed = false
        let heading = NSTextField(labelWithString: "Capture Area in 5 Seconds")
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        let detail = NSTextField(labelWithString:
            "Production AppKit menu, countdown and area editor.\n"
                + "Frozen source is synthetic and generated at the deadline.")
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
        expiry = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { _ in
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
    }

    @objc private func showMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menuController.menuNeedsUpdate(menu)
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }

    @objc private func start() {
        if delayed.start() { status.stringValue = "Countdown started — target focus stays unchanged" }
    }

    @objc private func cancel() {
        delayed.cancel()
        status.stringValue = "Cancelled — no capture will open"
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func showCountdown(_ seconds: Int) {
        if countdown == nil {
            countdown = DelayedCapturePanel { [weak self] in self?.cancel() }
            countdown?.orderFrontRegardless()
        }
        countdown?.update(seconds: seconds)
    }

    private func presentSource() {
        guard !overlays.isBusy, let screen = NSScreen.main else { return }
        status.stringValue = "Deadline reached — synthetic source generated now"
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
