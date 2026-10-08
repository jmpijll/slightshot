import AppKit

/// Everything drawn above the dimmed screenshot: annotations, the selection
/// outline with its handles, the size badge and the first-run hint.
///
/// Flipped, so its coordinate space matches `Annotation` and the exporter.
final class CanvasView: NSView {
    var sourceImage: CGImage? { didSet { invalidateComposite() } }
    var imageScale: CGFloat = 1 { didSet { invalidateComposite() } }
    var selection: CGRect? { didSet { invalidateComposite(); updateSourceVisibility() } }
    var annotations: [Annotation] = [] { didSet { invalidateComposite(); updateSourceVisibility() } }
    var liveAnnotation: Annotation? {
        didSet { livePatchIsValid = false; needsDisplay = true; updateSourceVisibility() }
    }
    var onSourceVisibilityChanged: ((CGRect?) -> Void)?
    private func updateSourceVisibility() {
        let hasRaster = annotations.contains { $0.rasterEffect != nil } || liveAnnotation?.rasterEffect != nil
        onSourceVisibilityChanged?(hasRaster ? selection : nil)
    }
    private var committedImage: CGImage?
    private var compositeIsValid = false
    private var livePatch: (image: CGImage, pixels: CGRect)?
    private var livePatchIsValid = false
    var accent: NSColor = .systemRed
    var alignSelectionToPoints = true
    var dimensionScale: CGFloat = 1
    var showDimensions = true
    var showHint = true { didSet { needsDisplay = true } }
    var hintText = "Drag to select an area  ·  Esc to cancel"

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        if let selection, selection.width > 0, selection.height > 0 {
            drawAnnotations(clippedTo: selection)
            drawOutline(selection)
            if showDimensions { drawSizeBadge(for: selection) }
        } else if showHint {
            drawHint()
        }
    }

    // MARK: - Pieces

    private func invalidateComposite() {
        compositeIsValid = false
        committedImage = nil
        livePatchIsValid = false
        livePatch = nil
        needsDisplay = true
    }

    private func drawAnnotations(clippedTo selection: CGRect) {
        guard !annotations.isEmpty || liveAnnotation != nil else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: selection).setClip()
        let hasRaster = annotations.contains { $0.rasterEffect != nil } || liveAnnotation?.rasterEffect != nil
        guard hasRaster else {
            for annotation in annotations { annotation.draw() }
            liveAnnotation?.draw()
            return
        }

        let proposed = alignSelectionToPoints ? selection.pixelAligned : selection
        let rect = sourceImage.map { Renderer.alignedSelectionRect(image: $0, scale: imageScale,
                                                                  selection: proposed) } ?? proposed
        if !compositeIsValid {
            committedImage = sourceImage.flatMap {
                Renderer.flatten(image: $0, scale: imageScale, selection: proposed, annotations: annotations)
            }
            compositeIsValid = true
        }
        guard let image = committedImage else {
            NSColor.black.setFill()
            NSBezierPath(rect: selection).fill()
            return
        }
        drawImage(image, in: CGRect(origin: rect.origin,
                                   size: CGSize(width: CGFloat(image.width) / imageScale,
                                                height: CGFloat(image.height) / imageScale)))
        guard let liveAnnotation else { return }
        guard let effect = liveAnnotation.rasterEffect else { liveAnnotation.draw(); return }
        if !livePatchIsValid {
            livePatch = Renderer.effectPatch(liveAnnotation, source: image, selection: rect, scale: imageScale)
            livePatchIsValid = true
        }
        if let patch = livePatch {
            let destination = CGRect(x: rect.minX + patch.pixels.minX / imageScale,
                                     y: rect.minY + patch.pixels.minY / imageScale,
                                     width: patch.pixels.width / imageScale,
                                     height: patch.pixels.height / imageScale)
            drawImage(patch.image, in: destination, replacing: true)
        } else {
            NSColor.black.setFill()
            NSBezierPath(rect: effect.rect).fill()
        }
    }

    private func drawImage(_ image: CGImage, in rect: CGRect, replacing: Bool = false) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        if replacing { context.setBlendMode(.copy) }
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    private var viewingZoom: CGFloat {
        max(0.01, convert(CGRect(x: 0, y: 0, width: 1, height: 1), to: nil).width)
    }

    private func drawOutline(_ selection: CGRect) {
        let scale = (window?.backingScaleFactor ?? 2) * viewingZoom
        let hairline = 1 / scale

        let border = NSBezierPath(rect: selection.insetBy(dx: -hairline / 2, dy: -hairline / 2))
        border.lineWidth = hairline * 2
        NSColor.white.withAlphaComponent(0.95).setStroke()
        border.stroke()

        // Handles: white squares with a dark hairline so they read on any content.
        for handle in SelectionHandle.allCases {
            let rect = handle.drawRect(in: selection, zoom: viewingZoom)
            NSColor.white.setFill()
            NSBezierPath(rect: rect).fill()
            NSColor.black.withAlphaComponent(0.45).setStroke()
            let outline = NSBezierPath(rect: rect.insetBy(dx: hairline / 2, dy: hairline / 2))
            outline.lineWidth = hairline
            outline.stroke()
        }
    }

    private func drawSizeBadge(for selection: CGRect) {
        let width = Int((selection.width * dimensionScale).rounded())
        let height = Int((selection.height * dimensionScale).rounded())
        let text = "\(width) × \(height)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11 / viewingZoom, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        let padding = CGSize(width: 7 / viewingZoom, height: 3 / viewingZoom)
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
