import AppKit

/// The annotation tools, in the same order Lightshot lists them.
nonisolated enum Tool: String, CaseIterable, Identifiable, Sendable {
    case pen, line, arrow, rectangle, marker, text, blur, pixelate

    var id: String { rawValue }

    var icon: ProductIcon {
        switch self {
        case .pen: .pen
        case .line: .line
        case .arrow: .arrow
        case .rectangle: .rectangle
        case .marker: .marker
        case .text: .text
        case .blur: .blur
        case .pixelate: .pixelate
        }
    }

    var title: String {
        switch self {
        case .pen: "Pen"
        case .line: "Line"
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .marker: "Marker"
        case .text: "Text"
        case .blur: "Blur"
        case .pixelate: "Pixelate"
        }
    }

    /// Marker strokes are translucent and much fatter, like a real highlighter.
    var widthMultiplier: CGFloat { self == .marker ? 6 : 1 }
    var strokeAlpha: CGFloat { self == .marker ? 0.35 : 1 }
    var usesColorAndWidth: Bool { self != .blur && self != .pixelate }
}
