import AppKit

/// The annotation tools, in the same order Lightshot lists them.
nonisolated enum Tool: String, CaseIterable, Identifiable, Sendable {
    case pen, line, arrow, rectangle, marker, text

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .pen: "pencil.tip"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .marker: "highlighter"
        case .text: "textformat"
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
        }
    }

    /// Marker strokes are translucent and much fatter, like a real highlighter.
    var widthMultiplier: CGFloat { self == .marker ? 6 : 1 }
    var strokeAlpha: CGFloat { self == .marker ? 0.35 : 1 }
}
