import AppKit

/// One drawn mark. Coordinates are always in *display points with a top-left
/// origin*, matching the flipped overlay view, so the same `draw()` renders
/// both on screen and into the exported image.
struct Annotation: Identifiable {
    enum Shape {
        case stroke(points: [CGPoint])   // pen and marker
        case line(from: CGPoint, to: CGPoint)
        case arrow(from: CGPoint, to: CGPoint)
        case rectangle(CGRect)
        case text(String, origin: CGPoint)
    }

    let id = UUID()
    var shape: Shape
    var color: NSColor
    var lineWidth: CGFloat
    var alpha: CGFloat = 1
    var fontSize: CGFloat = 18

    // MARK: - Drawing

    func draw() {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        let stroke = color.withAlphaComponent(color.alphaComponent * alpha)
        stroke.setStroke()
        stroke.setFill()

        switch shape {
        case .stroke(let points):
            guard points.count > 1 else {
                // A single tap still leaves a dot.
                if let p = points.first {
                    let r = lineWidth / 2
                    NSBezierPath(ovalIn: CGRect(x: p.x - r, y: p.y - r, width: lineWidth, height: lineWidth)).fill()
                }
                return
            }
            let path = Self.smoothPath(through: points)
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()

        case .line(let a, let b):
            let path = NSBezierPath()
            path.move(to: a)
            path.line(to: b)
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.stroke()

        case .arrow(let a, let b):
            drawArrow(from: a, to: b)

        case .rectangle(let rect):
            let path = NSBezierPath(rect: rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
            path.lineWidth = lineWidth
            path.lineJoinStyle = .miter
            path.stroke()

        case .text(let string, let origin):
            guard !string.isEmpty else { return }
            Self.attributedString(string, color: stroke, size: fontSize)
                .draw(at: origin)
        }
    }

    private func drawArrow(from a: CGPoint, to b: CGPoint) {
        let length = a.distance(to: b)
        guard length > 0.5 else { return }

        // Head scales with stroke weight but is capped so short arrows stay sane.
        let headLength = min(max(lineWidth * 4.5, 10), length)
        let headWidth = headLength * 0.62
        let angle = atan2(b.y - a.y, b.x - a.x)
        let base = CGPoint(x: b.x - cos(angle) * headLength, y: b.y - sin(angle) * headLength)
        let normal = CGPoint(x: -sin(angle), y: cos(angle))

        let shaft = NSBezierPath()
        shaft.move(to: a)
        // Stop the shaft inside the head so the tip stays crisp.
        shaft.line(to: CGPoint(x: b.x - cos(angle) * headLength * 0.75,
                               y: b.y - sin(angle) * headLength * 0.75))
        shaft.lineWidth = lineWidth
        shaft.lineCapStyle = .round
        shaft.stroke()

        let head = NSBezierPath()
        head.move(to: b)
        head.line(to: CGPoint(x: base.x + normal.x * headWidth / 2, y: base.y + normal.y * headWidth / 2))
        head.line(to: CGPoint(x: base.x - normal.x * headWidth / 2, y: base.y - normal.y * headWidth / 2))
        head.close()
        head.fill()
    }

    /// Catmull-Rom smoothing so freehand strokes don't look like polylines.
    private static func smoothPath(through points: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            for p in points.dropFirst() { path.line(to: p) }
            return path
        }
        for i in 0..<(points.count - 1) {
            let p0 = points[max(i - 1, 0)]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = points[min(i + 2, points.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.curve(to: p2, controlPoint1: c1, controlPoint2: c2)
        }
        return path
    }

    static func attributedString(_ string: String, color: NSColor, size: CGFloat) -> NSAttributedString {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = CGSize(width: 0, height: -1)
        return NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: color,
            .shadow: shadow,
        ])
    }

    /// Bounding box including stroke weight, used for dirty-rect invalidation.
    var dirtyBounds: CGRect {
        let pad = max(lineWidth * 5, 12)
        switch shape {
        case .stroke(let points):
            guard var box = points.first.map({ CGRect(origin: $0, size: .zero) }) else { return .zero }
            for p in points { box = box.union(CGRect(origin: p, size: .zero)) }
            return box.insetBy(dx: -pad, dy: -pad)
        case .line(let a, let b), .arrow(let a, let b):
            return CGRect(corner: a, corner: b).insetBy(dx: -pad, dy: -pad)
        case .rectangle(let r):
            return r.insetBy(dx: -pad, dy: -pad)
        case .text(let s, let origin):
            let size = Self.attributedString(s, color: .white, size: fontSize).size()
            return CGRect(origin: origin, size: size).insetBy(dx: -pad, dy: -pad)
        }
    }
}
