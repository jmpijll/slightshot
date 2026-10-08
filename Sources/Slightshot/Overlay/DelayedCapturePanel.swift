import AppKit

/// A passive HUD leaves keyboard focus with the application being captured.
final class DelayedCapturePanel: NSPanel {
    private let label = NSTextField(labelWithString: "Capture in 5…")
    private let onCancel: () -> Void

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        super.init(contentRect: CGRect(x: 0, y: 0, width: 250, height: 52),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        setAccessibilityLabel("Delayed screenshot")
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.widthAnchor.constraint(equalToConstant: 130).isActive = true
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelCapture))
        cancel.bezelStyle = .rounded
        cancel.setAccessibilityLabel("Cancel delayed capture")
        let row = NSStackView(views: [label, cancel])
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        background.appearance = NSAppearance(named: .darkAqua)
        contentView = background
        background.addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            row.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let screen {
            setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - frame.width / 2,
                                  y: screen.visibleFrame.minY + 24))
        }
    }

    func update(seconds: Int) { label.stringValue = "Capture in \(seconds)…" }
    @objc private func cancelCapture() { onCancel() }
}
