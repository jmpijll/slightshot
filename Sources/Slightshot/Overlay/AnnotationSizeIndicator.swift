import AppKit

/// A transient size halo centered on the pointer, outside the annotation renderer.
final class AnnotationSizeIndicator: NSView {
    private var dismissal: Task<Void, Never>?

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 18, height: 18))
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        NSColor(hex: "#FF3B30")!.withAlphaComponent(0.14).setFill()
        circle.fill()
        NSColor.white.withAlphaComponent(0.95).setStroke()
        circle.lineWidth = 1.25
        circle.stroke()
    }

    func show(_ change: AnnotationSizeChange, at point: CGPoint, in host: NSView) {
        dismissal?.cancel()
        setAccessibilityLabel(change.label)
        if superview !== host { removeFromSuperview(); host.addSubview(self) }
        let diameter = change.indicatorDiameter
        frame = CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2,
                       width: diameter, height: diameter)
        needsDisplay = true
        isHidden = false
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.isHidden = true
        }
    }

    func move(to point: CGPoint, in host: NSView) {
        guard !isHidden, superview === host else { return }
        setFrameOrigin(CGPoint(x: point.x - frame.width / 2, y: point.y - frame.height / 2))
    }

    func hide() { dismissal?.cancel(); isHidden = true }
}
