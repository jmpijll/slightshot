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

}
