import AppKit

/// Everything drawn above the dimmed screenshot: annotations, the selection
/// outline with its handles, the size badge and the first-run hint.
///
/// Flipped, so its coordinate space matches `Annotation` and the exporter.
final class CanvasView: NSView {
    var selection: CGRect? { didSet { needsDisplay = true } }
    var annotations: [Annotation] = [] { didSet { needsDisplay = true } }
    var liveAnnotation: Annotation? { didSet { needsDisplay = true } }
    var accent: NSColor = .systemRed
    var showDimensions = true
    var showHint = true { didSet { needsDisplay = true } }
    var hintText = "Drag to select an area  ·  Esc to cancel"

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        if let selection, selection.width >= 1, selection.height >= 1 {
            drawAnnotations(clippedTo: selection)
            drawOutline(selection)
            if showDimensions { drawSizeBadge(for: selection) }
        } else if showHint {
            drawHint()
        }
    }

    // MARK: - Pieces

    private func drawAnnotations(clippedTo selection: CGRect) {
        guard !annotations.isEmpty || liveAnnotation != nil else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: selection).setClip()
        for annotation in annotations { annotation.draw() }
        liveAnnotation?.draw()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawOutline(_ selection: CGRect) {
        let scale = window?.backingScaleFactor ?? 2
        let hairline = 1 / scale

        let border = NSBezierPath(rect: selection.insetBy(dx: -hairline / 2, dy: -hairline / 2))
        border.lineWidth = hairline * 2
        NSColor.white.withAlphaComponent(0.95).setStroke()
        border.stroke()

        // Handles: white squares with a dark hairline so they read on any content.
        for handle in SelectionHandle.allCases {
            let rect = handle.drawRect(in: selection)
            NSColor.white.setFill()
            NSBezierPath(rect: rect).fill()
            NSColor.black.withAlphaComponent(0.45).setStroke()
            let outline = NSBezierPath(rect: rect.insetBy(dx: hairline / 2, dy: hairline / 2))
            outline.lineWidth = hairline
            outline.stroke()
        }
    }

    private func drawSizeBadge(for selection: CGRect) {
        let text = "\(Int(selection.width.rounded())) × \(Int(selection.height.rounded()))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        let padding = CGSize(width: 7, height: 3)
        let badgeSize = CGSize(width: textSize.width + padding.width * 2,
                               height: textSize.height + padding.height * 2)

        // Above the selection by default; tucked inside when there is no room.
        var origin = CGPoint(x: selection.minX, y: selection.minY - badgeSize.height - 5)
        if origin.y < 2 { origin.y = selection.minY + 5 }
        origin.x = min(max(2, origin.x), bounds.maxX - badgeSize.width - 2)

        let badge = CGRect(origin: origin, size: badgeSize)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
        string.draw(at: CGPoint(x: badge.minX + padding.width, y: badge.minY + padding.height))
    }

    private func drawHint() {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
        ]
        let string = NSAttributedString(string: hintText, attributes: attributes)
        let textSize = string.size()
        let badge = CGRect(x: (bounds.width - textSize.width) / 2 - 14,
                           y: bounds.height * 0.14 - textSize.height / 2 - 8,
                           width: textSize.width + 28, height: textSize.height + 16)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 9, yRadius: 9).fill()
        string.draw(at: CGPoint(x: badge.minX + 14, y: badge.minY + 8))
    }
}
