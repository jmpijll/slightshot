import AppKit

/// The in-place text field the Text tool drops onto the screenshot.
/// Escape cancels, ⌘↩ (or clicking elsewhere) commits, ↩ inserts a newline.
final class TextEntryView: NSTextView {
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private let minimumWidth: CGFloat = 64

    init(origin: CGPoint, color: NSColor, fontSize: CGFloat, maxWidth: CGFloat) {
        let container = NSTextContainer(size: NSSize(width: max(maxWidth, minimumWidth),
                                                     height: .greatestFiniteMagnitude))
        container.widthTracksTextView = false
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)

        super.init(frame: NSRect(x: origin.x, y: origin.y, width: minimumWidth, height: fontSize * 1.6),
                   textContainer: container)

        font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        textColor = color
        insertionPointColor = color
        drawsBackground = false
        isRichText = false
        isVerticallyResizable = true
        isHorizontallyResizable = true
        textContainerInset = NSSize(width: 4, height: 3)
        allowsUndo = true
        // Straight quotes and no auto-capitalisation: this is annotation, not prose.
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func keyDown(with event: NSEvent) {
        let isCommand = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 53:  // Escape
            onCancel?()
        case 36 where isCommand, 76:  // ⌘↩ or numpad Enter
            onCommit?(string)
        default:
            super.keyDown(with: event)
        }
    }

    override func didChangeText() {
        super.didChangeText()
        resizeToFit()
    }

    func resizeToFit() {
        guard let layout = layoutManager, let container = textContainer else { return }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let width = max(minimumWidth, used.width + textContainerInset.width * 2 + 8)
        let height = max((font?.pointSize ?? 18) * 1.6, used.height + textContainerInset.height * 2)
        setFrameSize(NSSize(width: width, height: height))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // A dashed box so it is obvious where typing will land.
        let box = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        box.lineWidth = 1
        box.setLineDash([3, 3], count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.7).setStroke()
        box.stroke()
        super.draw(dirtyRect)
    }
}
