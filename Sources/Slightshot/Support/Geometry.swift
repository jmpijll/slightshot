import CoreGraphics
import Foundation

nonisolated extension CGRect {
    /// A normalized rect from two arbitrary corner points.
    init(corner a: CGPoint, corner b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y),
                  width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// A square from `anchor` sized by the longer drag axis, kept inside `bounds`.
    init(square anchor: CGPoint, toward point: CGPoint, within bounds: CGRect) {
        let dx = point.x - anchor.x, dy = point.y - anchor.y
        let side = max(0, min(max(abs(dx), abs(dy)),
                              dx < 0 ? anchor.x - bounds.minX : bounds.maxX - anchor.x,
                              dy < 0 ? anchor.y - bounds.minY : bounds.maxY - anchor.y))
        self.init(corner: anchor, corner: CGPoint(x: anchor.x + (dx < 0 ? -side : side),
                                                  y: anchor.y + (dy < 0 ? -side : side)))
    }

    /// Rounds every edge to the nearest whole pixel so the crop lands on exact pixel boundaries.
    var pixelAligned: CGRect { pixelAligned(scale: 1) }

    /// Rounds every edge to the nearest device pixel at `scale` pixels per point.
    func pixelAligned(scale: CGFloat) -> CGRect {
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let left = snap(minX), top = snap(minY)
        return CGRect(x: left, y: top, width: snap(maxX) - left, height: snap(maxY) - top)
    }

    func clamped(to bounds: CGRect) -> CGRect {
        var r = intersection(bounds)
        if r.isNull { r = CGRect(origin: origin, size: .zero) }
        return r
    }
}

nonisolated extension CGPoint {
    func offsetBy(dx: CGFloat, dy: CGFloat) -> CGPoint { CGPoint(x: x + dx, y: y + dy) }
    func distance(to other: CGPoint) -> CGFloat { hypot(x - other.x, y - other.y) }
}

nonisolated extension Array {
    /// Bounds-checked subscript, for the handful of places where an index is
    /// derived from display geometry that can change mid-capture.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
