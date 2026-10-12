import Foundation

nonisolated struct AnnotationSizeChange: Equatable {
    let isText: Bool
    let value: CGFloat

    var label: String { "\(isText ? "Text size" : "Thickness") \(Int(value.rounded())) pt" }
}

/// Converts wheel ticks or accumulated trackpad motion into bounded style changes.
nonisolated struct AnnotationSizeScroll {
    private var remainder: CGFloat = 0
    private var previousTool: Tool?
    private var previousPrecise = false

    static func supports(_ tool: Tool?) -> Bool {
        guard let tool else { return false }
        return tool != .blur && tool != .pixelate && tool != .step
    }

    mutating func reset() { remainder = 0; previousTool = nil }

    mutating func adjust(tool: Tool, width: CGFloat, fontSize: CGFloat, delta: CGFloat,
                         precise: Bool = false) -> AnnotationSizeChange? {
        guard Self.supports(tool), delta.isFinite, delta != 0 else { reset(); return nil }
        if previousTool != tool || previousPrecise != precise { remainder = 0 }
        previousTool = tool
        previousPrecise = precise
        remainder += min(100, max(-100, delta / (precise ? 8 : 1)))
        let steps = remainder.rounded(.towardZero)
        guard steps != 0 else { return nil }
        remainder -= steps
        let isText = tool == .text
        let value = isText ? min(48, max(10, fontSize + steps * 2)) : min(12, max(1, width + steps))
        return AnnotationSizeChange(isText: isText, value: value)
    }
}
