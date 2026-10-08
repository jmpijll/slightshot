import AppKit

/// A normal native image window; imported pixels never acquire monitor geometry.
final class ClipboardEditorWindow: NSWindow, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let scrollView = NSScrollView()
    private let editor: OverlayView
    private var scrollObserver: NSObjectProtocol?

    static var availableImageSize: CGSize {
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        return CGSize(width: max(320, min(1000, visible.width - 100)),
                      height: max(240, min(700, visible.height - 150)))
    }

    init(editor: OverlayView) {
        self.editor = editor
        super.init(contentRect: editor.bounds, styleMask: [.titled, .closable, .miniaturizable],
                   backing: .buffered, defer: false)
        title = "Edit Image from Clipboard"
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        let host = ClipboardEditorHost(frame: editor.bounds)
        contentView = host
        scrollView.frame = host.bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 1
        scrollView.maxMagnification = max(4, editor.source.scale)
        scrollView.documentView = editor
        scrollView.contentView.postsBoundsChangedNotifications = true
        host.addSubview(scrollView)
        editor.prepareClipboardEditor(toolbarHost: host)
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak editor] _ in
            MainActor.assumeIsolated { editor?.layoutToolbars() }
        }
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .right
        let controls = NSStackView(views: [
            NSButton(title: "Fit", target: self, action: #selector(fit)),
            NSButton(title: "100%", target: self, action: #selector(actualSize)),
        ])
        controls.orientation = .horizontal
        controls.frame = CGRect(x: 0, y: 0, width: 115, height: 28)
        accessory.view = controls
        addTitlebarAccessoryViewController(accessory)
        delegate = self
        center()
    }

    @objc private func fit() {
        scrollView.magnification = 1
        editor.layoutToolbars()
        makeFirstResponder(editor)
    }

    @objc private func actualSize() {
        scrollView.magnification = editor.source.scale
        editor.layoutToolbars()
        makeFirstResponder(editor)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onClose?()
        return false // The coordinator closes only after it can release ownership.
    }

    override func close() {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        super.close()
    }
}

private final class ClipboardEditorHost: NSView {
    override var isFlipped: Bool { true }
}

final class ClipboardEditorWindows: OverlayPresentation {
    private var window: ClipboardEditorWindow?

    func show(_ views: [OverlayView], focused: OverlayView?) {
        guard let view = views.first else { return }
        if window == nil {
            let editor = ClipboardEditorWindow(editor: view)
            editor.onClose = { [weak view] in view?.toolbarDidRequestClose() }
            window = editor
        }
        NSApp.activate(ignoringOtherApps: true)
        focus(focused ?? view)
    }

    func focus(_ view: OverlayView) {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(view)
    }

    func hide() { window?.orderOut(nil) }

    func close() {
        window?.delegate = nil
        window?.close()
        window = nil
        NSCursor.arrow.set()
    }
}
