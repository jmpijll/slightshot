import AppKit

extension OverlayView {
    func clampToBounds(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, point.x), source.size.width),
                y: min(max(0, point.y), source.size.height))
    }

    func squared(_ rect: CGRect, from anchor: CGPoint, to point: CGPoint) -> CGRect {
        let side = max(abs(point.x - anchor.x), abs(point.y - anchor.y))
        let end = CGPoint(x: anchor.x + (point.x < anchor.x ? -side : side),
                          y: anchor.y + (point.y < anchor.y ? -side : side))
        return CGRect(corner: anchor, corner: end).clamped(to: source.bounds)
    }

    /// Shift-constrains a line to the nearest 45° increment.
    func axisLocked(from start: CGPoint, to end: CGPoint) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let length = hypot(dx, dy)
        return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
    }

}
