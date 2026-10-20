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

/// The part of a recording that Save keeps, in source seconds with an
/// inclusive start and an exclusive end. Annotations keep source times, so
/// changing the trim never edits them.
nonisolated struct VideoTrim: Equatable, Sendable {
    static let minimumLength: TimeInterval = 1.0 / 30

    let start: TimeInterval
    let end: TimeInterval
    var duration: TimeInterval { end - start }

    init(start: TimeInterval, end: TimeInterval, recording: TimeInterval) {
        let limit = recording.isFinite ? max(0, recording) : 0
        let gap = min(Self.minimumLength, limit)
        let lower = start.isFinite ? min(max(0, start), limit - gap) : 0
        self.start = lower
        self.end = end.isFinite ? min(limit, max(lower + gap, end)) : limit
    }

    static func whole(_ recording: TimeInterval) -> Self { Self(start: 0, end: recording, recording: recording) }

    func isWhole(of recording: TimeInterval) -> Bool { self == .whole(recording) }

    func contains(_ time: TimeInterval) -> Bool { time >= start && time < end }

    func clamp(_ time: TimeInterval) -> TimeInterval { min(max(start, time), end) }
}

extension VideoAnnotation {
    /// The interval inside a trim, moved so the trim's start becomes zero.
    /// Nil when no part of the annotation is kept.
    func trimmed(to trim: VideoTrim) -> Self? {
        let lower = max(start, trim.start)
        let upper = min(end, trim.end)
        guard upper > lower else { return nil }
        return Self(annotation: annotation, start: lower - trim.start, end: upper - trim.start)
    }
}
