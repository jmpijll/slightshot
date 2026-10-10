import AppKit

/// A single selected annotation's visible interval, with two draggable handles.
final class VideoRangeControl: NSView {
    var duration: TimeInterval = 1
    var start: TimeInterval = 0
    var end: TimeInterval = 1
    var playhead: TimeInterval = 0
    var isEnabled = false { didSet { needsDisplay = true } }
    var onBeginChange: (() -> Void)?
    var onChange: ((TimeInterval, TimeInterval) -> Void)?
    private var draggingStart = false

    override var isFlipped: Bool { true }
    private var track: CGRect { bounds.insetBy(dx: 10, dy: 10) }
    private func x(_ time: TimeInterval) -> CGFloat { track.minX + track.width * time / max(duration, 0.001) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4).fill()
        if isEnabled {
            NSColor.controlAccentColor.withAlphaComponent(0.5).setFill()
            CGRect(x: x(start), y: track.minY, width: x(end) - x(start), height: track.height).fill()
            NSColor.controlAccentColor.setFill()
            for time in [start, end] {
                NSBezierPath(roundedRect: CGRect(x: x(time) - 5, y: track.minY - 5,
                    width: 10, height: track.height + 10), xRadius: 3, yRadius: 3).fill()
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
}
