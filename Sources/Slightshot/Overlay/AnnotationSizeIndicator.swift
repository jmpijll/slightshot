import AppKit

/// Transient editor chrome, never included by the annotation renderer.
final class AnnotationSizeIndicator: NSView {
    private let label = NSTextField(labelWithString: "")
    private var dismissal: Task<Void, Never>?

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 150, height: 32))
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        let effect = NSVisualEffectView(frame: bounds)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .vibrantDark)
        addSubview(effect)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.frame = CGRect(x: 12, y: 8, width: 126, height: 17)
        addSubview(label)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ change: AnnotationSizeChange, at point: CGPoint, in host: NSView) {
        dismissal?.cancel()
        label.stringValue = change.label
        setAccessibilityLabel(change.label)
        if superview !== host { removeFromSuperview(); host.addSubview(self) }
        var origin = CGPoint(x: point.x + 18, y: point.y + 18)
        if origin.x + frame.width > host.bounds.maxX - 4 { origin.x = point.x - frame.width - 18 }
        if origin.y + frame.height > host.bounds.maxY - 4 { origin.y = point.y - frame.height - 18 }
        origin.x = max(host.bounds.minX + 4, min(origin.x, host.bounds.maxX - frame.width - 4))
        origin.y = max(host.bounds.minY + 4, min(origin.y, host.bounds.maxY - frame.height - 4))
        setFrameOrigin(origin)
        isHidden = false
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.isHidden = true
        }
    }

    func hide() { dismissal?.cancel(); isHidden = true }
}
