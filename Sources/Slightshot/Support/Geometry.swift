import CoreGraphics
import Foundation

nonisolated extension CGRect {
    /// A normalized rect from two arbitrary corner points.
    init(corner a: CGPoint, corner b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y),
                  width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Rounds to whole pixels so the crop lands on exact pixel boundaries.
    var pixelAligned: CGRect {
        CGRect(x: minX.rounded(.down), y: minY.rounded(.down),
               width: width.rounded(), height: height.rounded())
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
