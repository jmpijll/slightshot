import AppKit

/// A click-through boundary that stays visible while the selected screen is live.
/// ScreenCaptureKit excludes this panel along with every other Slightshot window.
final class RecordingOutlinePanel: NSPanel {
    init(screen: NSScreen, selection: CGRect) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        contentView = RecordingOutlineView(frame: CGRect(origin: .zero, size: screen.frame.size),
                                           selection: selection)
        setAccessibilityElement(false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class RecordingOutlineView: NSView {
    private let selection: CGRect
    override var isFlipped: Bool { true }

    init(frame: CGRect, selection: CGRect) {
        self.selection = selection
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        // Four points inside the exact crop edge: dark / red / red / dark.
        // The contrast remains readable over both light and dark source content.
        fillRing(inset: 0, width: 4, color: NSColor(srgbRed: 0.09, green: 0.09, blue: 0.1, alpha: 1))
        fillRing(inset: 1, width: 2, color: NSColor(srgbRed: 1, green: 0.231, blue: 0.188, alpha: 1))
    }

    private func fillRing(inset: CGFloat, width: CGFloat, color: NSColor) {
        let path = NSBezierPath(rect: selection.insetBy(dx: inset, dy: inset))
        path.appendRect(selection.insetBy(dx: inset + width, dy: inset + width))
        path.windingRule = .evenOdd
        color.setFill()
        path.fill()
    }
}
