import AppKit

/// An interval of the recording with two draggable handles: the kept trim or a
/// selected annotation's visible period.
final class VideoRangeControl: NSView {
    var duration: TimeInterval = 1
    var start: TimeInterval = 0 { didSet { needsDisplay = true } }
    var end: TimeInterval = 1 { didSet { needsDisplay = true } }
    var playhead: TimeInterval = 0
    var tint = NSColor.controlAccentColor
    /// Dims the parts of the timeline that Save removes.
    var kept: VideoTrim? { didSet { needsDisplay = true } }
    var isEnabled = false { didSet { needsDisplay = true } }
    var onBeginChange: (() -> Void)?
    var onChange: ((TimeInterval, TimeInterval) -> Void)?
    var onEndChange: (() -> Void)?
    private var draggingStart = false

    override var isFlipped: Bool { true }
    private var track: CGRect { bounds.insetBy(dx: 10, dy: 10) }
    private func x(_ time: TimeInterval) -> CGFloat { track.minX + track.width * time / max(duration, 0.001) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4).fill()
        if isEnabled {
            tint.withAlphaComponent(0.5).setFill()
            CGRect(x: x(start), y: track.minY, width: x(end) - x(start), height: track.height).fill()
            tint.setFill()
            for time in [start, end] {
                NSBezierPath(roundedRect: CGRect(x: x(time) - 5, y: track.minY - 5,
                    width: 10, height: track.height + 10), xRadius: 3, yRadius: 3).fill()
            }
        }
        if let kept, !kept.isWhole(of: duration) {
            NSColor.windowBackgroundColor.withAlphaComponent(0.7).setFill()
            for (from, to) in [(0, kept.start), (kept.end, duration)] where to > from {
                CGRect(x: x(from) - 5, y: track.minY - 5, width: x(to) - x(from) + 10, height: track.height + 10).fill()
            }
        }
        NSColor.labelColor.setFill()
        CGRect(x: x(playhead) - 1, y: track.minY - 7, width: 2, height: track.height + 14).fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        draggingStart = abs(point.x - x(start)) <= abs(point.x - x(end))
        onBeginChange?()
        mouseDragged(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        let time = min(duration, max(0, (point.x - track.minX) / track.width * duration))
        let gap = min(1.0 / 30, duration)
        if draggingStart { start = min(time, end - gap) } else { end = max(time, start + gap) }
        onChange?(start, end)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        onEndChange?()
    }
}

/// Editor time fields show hundredths of a second in the user's locale.
enum VideoTimeText {
    private static let format: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    static func string(_ time: TimeInterval) -> String { format.string(for: time) ?? "" }

    /// Accepts the user's locale (1,50) and a period (1.50).
    static func parse(_ text: String) -> TimeInterval? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard let value = format.number(from: text)?.doubleValue ?? Double(text), value.isFinite else { return nil }
        return value
    }

    /// The typed time, or nil when the text is unchanged or not a number.
    static func edited(_ text: String, committed: TimeInterval) -> TimeInterval? {
        text == string(committed) ? nil : parse(text)
    }
}
