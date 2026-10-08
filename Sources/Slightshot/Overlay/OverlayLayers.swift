import AppKit

/// Draws the frozen screenshot. Backed directly by a `CALayer` so the pixels are
/// uploaded to the GPU once and never re-rasterised while the user drags.
///
/// Deliberately *not* flipped: `CALayer.contents` renders a `CGImage` upright in
/// the default (bottom-left origin) geometry, and leaving it alone avoids a
/// second, invisible flip.
final class ScreenshotView: NSView {
    init(image: CGImage, frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.contents = image
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .nearest
        layer?.minificationFilter = .trilinear
    }

    /// Source-containing raster composition replaces these pixels in CanvasView.
    func exclude(_ selection: CGRect?) {
        guard let selection else { layer?.mask = nil; return }
        let mask = CAShapeLayer()
        mask.frame = bounds
        mask.fillRule = .evenOdd
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addRect(CGRect(x: selection.minX, y: bounds.height - selection.maxY,
                            width: selection.width, height: selection.height))
        mask.path = path
        layer?.mask = mask
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The darkened veil with the selection punched out of it.
///
/// Uses an even-odd `CAShapeLayer` so that resizing the selection swaps a single
/// path instead of redrawing the whole display — this is what keeps dragging
/// smooth on a 6K screen.
///
/// Also unflipped, so `update(hole:)` converts from the overlay's top-left
/// origin space explicitly rather than relying on `isGeometryFlipped`.
final class DimView: NSView {
    private var shapeLayer: CAShapeLayer? { layer as? CAShapeLayer }

    override func makeBackingLayer() -> CALayer {
        let layer = CAShapeLayer()
        layer.fillRule = .evenOdd
        layer.fillColor = NSColor.black.withAlphaComponent(0.45).cgColor
        return layer
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var opacity: CGFloat = 0.45 {
        didSet { shapeLayer?.fillColor = NSColor.black.withAlphaComponent(opacity).cgColor }
    }

    /// `hole` is given in the overlay's flipped (top-left origin) coordinates.
    /// Passing `nil` dims the entire display.
    func update(hole: CGRect?) {
        let path = CGMutablePath()
        path.addRect(bounds)
        if let hole, hole.width > 0, hole.height > 0 {
            path.addRect(CGRect(x: hole.minX, y: bounds.height - hole.maxY,
                                width: hole.width, height: hole.height))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shapeLayer?.path = path
        CATransaction.commit()
    }
}
