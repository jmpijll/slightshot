import AppKit

/// The pixel loupe that follows the crosshair, showing a magnified grid, the
/// exact cursor coordinates and the colour under the pointer.
///
/// Unflipped on purpose: `CGContext.draw(_:in:)` renders a `CGImage` upright in
/// default geometry, which keeps the magnified pixels the right way up.
final class MagnifierView: NSView {
    static let zoomSide: CGFloat = 136
    static let infoHeight: CGFloat = 38
    static let pixelsAcross = 17
    static let totalSize = NSSize(width: zoomSide, height: zoomSide + infoHeight)

    private let display: CapturedDisplay
    private var point: CGPoint = .zero
    private var pickedColor: NSColor = .black
    var accentColor: NSColor = .systemRed

    init(display: CapturedDisplay) {
        self.display = display
        super.init(frame: NSRect(origin: .zero, size: Self.totalSize))
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.6)
            s.shadowBlurRadius = 8
            s.shadowOffset = .zero
            return s
        }()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// `location` is in the overlay's flipped (top-left origin) coordinates.
    func move(to location: CGPoint) {
        point = location
        pickedColor = display.color(at: location) ?? .black
        needsDisplay = true
    }

    var currentColor: NSColor { pickedColor }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let zoomRect = NSRect(x: 0, y: Self.infoHeight, width: Self.zoomSide, height: Self.zoomSide)
        NSColor.black.setFill()
        bounds.fill()

        // Magnified pixels, nearest-neighbour so individual pixels stay square.
        let span = Self.pixelsAcross
        let half = span / 2
        let px = Int((point.x * display.scale).rounded(.down)) - half
        let py = Int((point.y * display.scale).rounded(.down)) - half
        if let crop = display.image.cropping(to: CGRect(x: px, y: py, width: span, height: span)) {
            ctx.saveGState()
            ctx.interpolationQuality = .none
            ctx.draw(crop, in: zoomRect)
            ctx.restoreGState()
        }

        // Pixel grid.
        let cell = Self.zoomSide / CGFloat(span)
        NSColor.white.withAlphaComponent(0.12).setStroke()
        let grid = NSBezierPath()
        grid.lineWidth = 1 / (window?.backingScaleFactor ?? 2)
        for i in 1..<span {
            let offset = (CGFloat(i) * cell).rounded()
            grid.move(to: CGPoint(x: offset, y: zoomRect.minY))
            grid.line(to: CGPoint(x: offset, y: zoomRect.maxY))
            grid.move(to: CGPoint(x: 0, y: zoomRect.minY + offset))
            grid.line(to: CGPoint(x: Self.zoomSide, y: zoomRect.minY + offset))
        }
        grid.stroke()

        // The centre cell is the pixel actually under the crosshair.
        let centre = NSRect(x: CGFloat(half) * cell, y: zoomRect.minY + CGFloat(half) * cell,
                            width: cell, height: cell)
        accentColor.setStroke()
        let marker = NSBezierPath(rect: centre.insetBy(dx: -0.5, dy: -0.5))
        marker.lineWidth = 1.5
        marker.stroke()

        // Info strip: coordinates on the left, colour swatch plus hex on the right.
        NSColor.black.withAlphaComponent(0.92).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: Self.infoHeight).fill()

        let coords = "\(Int(point.x.rounded())), \(Int(point.y.rounded()))"
        draw(text: coords, at: CGPoint(x: 8, y: 21), color: .white)

        let hex = pickedColor.hexString
        let swatch = NSRect(x: 8, y: 5, width: 11, height: 11)
        pickedColor.setFill()
        NSBezierPath(roundedRect: swatch, xRadius: 2, yRadius: 2).fill()
        NSColor.white.withAlphaComponent(0.5).setStroke()
        NSBezierPath(roundedRect: swatch, xRadius: 2, yRadius: 2).stroke()
        draw(text: hex, at: CGPoint(x: 25, y: 4), color: NSColor.white.withAlphaComponent(0.85))
    }

    private func draw(text: String, at origin: CGPoint, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: color,
        ]
        NSAttributedString(string: text, attributes: attributes).draw(at: origin)
    }
}
