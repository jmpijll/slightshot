import AppKit

/// The eight drag handles around the selection. All rects are in the overlay's
/// flipped (top-left origin) coordinate space.
nonisolated enum SelectionHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    static let drawSize: CGFloat = 7
    static let hitSize: CGFloat = 16

    func anchor(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .top: CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .right: CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .left: CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    func drawRect(in rect: CGRect) -> CGRect {
        let p = anchor(in: rect)
        return CGRect(x: p.x - Self.drawSize / 2, y: p.y - Self.drawSize / 2,
                      width: Self.drawSize, height: Self.drawSize)
    }

    func hitRect(in rect: CGRect) -> CGRect {
        let p = anchor(in: rect)
        return CGRect(x: p.x - Self.hitSize / 2, y: p.y - Self.hitSize / 2,
                      width: Self.hitSize, height: Self.hitSize)
    }

    static func hit(_ point: CGPoint, in rect: CGRect) -> SelectionHandle? {
        // Corners win over edges when the hit areas overlap on a small selection.
        let ordered: [SelectionHandle] = [.topLeft, .topRight, .bottomLeft, .bottomRight,
                                          .top, .bottom, .left, .right]
        return ordered.first { $0.hitRect(in: rect).contains(point) }
    }

    @MainActor var cursor: NSCursor {
        switch self {
        case .left, .right: .resizeLeftRight
        case .top, .bottom: .resizeUpDown
        case .topLeft, .topRight, .bottomLeft, .bottomRight: .crosshair
        }
    }

    /// Returns the rect produced by dragging this handle to `point`.
    /// The result is normalised, so dragging past the opposite edge flips it.
    func resized(_ rect: CGRect, to point: CGPoint) -> CGRect {
        var minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        switch self {
        case .topLeft: minX = point.x; minY = point.y
        case .top: minY = point.y
        case .topRight: maxX = point.x; minY = point.y
        case .right: maxX = point.x
        case .bottomRight: maxX = point.x; maxY = point.y
        case .bottom: maxY = point.y
        case .bottomLeft: minX = point.x; maxY = point.y
        case .left: minX = point.x
        }
        return CGRect(corner: CGPoint(x: minX, y: minY), corner: CGPoint(x: maxX, y: maxY))
    }
}
