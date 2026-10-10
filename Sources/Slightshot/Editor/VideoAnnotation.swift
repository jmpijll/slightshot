import Foundation

/// A screenshot mark in source-video pixels with an inclusive start and an
/// exclusive end. Its identity follows the mark when the time range changes.
struct VideoAnnotation: Identifiable {
    var annotation: Annotation
    var id: UUID { annotation.id }
    private var lowerBound: TimeInterval
    private var upperBound: TimeInterval

    var start: TimeInterval {
        get { lowerBound }
        set { lowerBound = min(Self.finiteTime(newValue), upperBound) }
    }

    var end: TimeInterval {
        get { upperBound }
        set { upperBound = max(Self.finiteTime(newValue), lowerBound) }
    }

    var duration: TimeInterval { end - start }

    init(annotation: Annotation, start: TimeInterval, end: TimeInterval) {
        self.annotation = annotation
        lowerBound = Self.finiteTime(start)
        upperBound = max(lowerBound, Self.finiteTime(end))
    }

    func isActive(at time: TimeInterval) -> Bool {
        time.isFinite && time >= start && time < end
    }

    mutating func setRange(start: TimeInterval, end: TimeInterval, duration: TimeInterval) {
        let limit = Self.finiteTime(duration)
        lowerBound = min(Self.finiteTime(start), limit)
        upperBound = min(max(lowerBound, Self.finiteTime(end)), limit)
    }

    func clamped(to duration: TimeInterval) -> Self {
        var copy = self
        copy.setRange(start: start, end: end, duration: duration)
        return copy
    }

    static func active(in annotations: [Self], at time: TimeInterval) -> [Annotation] {
        annotations.filter { $0.isActive(at: time) }.map(\.annotation)
    }

    private static func finiteTime(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? max(0, value) : 0
    }
}
