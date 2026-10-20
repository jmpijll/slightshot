import AppKit

extension OverlayView {
    func clampToBounds(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, point.x), source.size.width),
                y: min(max(0, point.y), source.size.height))
    }

    var viewingZoom: CGFloat {
        capturedDisplay == nil ? max(0.01, convert(CGRect(x: 0, y: 0, width: 1, height: 1), to: nil).width) : 1
    }

    /// Shift-constrains a line to the nearest 45° increment.
    func axisLocked(from start: CGPoint, to end: CGPoint) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let length = hypot(dx, dy)
        return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
    }

}
