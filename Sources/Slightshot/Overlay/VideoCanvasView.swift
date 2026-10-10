import AppKit

/// Video frames and screenshot annotations share the same top-left source coordinates.
final class VideoCanvasView: NSView {
    let sourceSize: CGSize
    var onCommit: ((Annotation) -> Void)?
    var onSelect: ((UUID?) -> Void)?
    var onPause: (() -> Void)?
    var tool: Tool?
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 4
    var annotations: [VideoAnnotation] = []
    var selectedID: UUID?
    var time: TimeInterval = 0
    private var sourceImage: CGImage?
    private var renderedImage: CGImage?
    private var anchor: CGPoint?
    private var points: [CGPoint] = []
    private var live: Annotation?
    private var textEntry: TextEntryView?
    private var textOrigin: CGPoint = .zero
    private var textFontSize: CGFloat = 24

    init(sourceSize: CGSize) {
        self.sourceSize = sourceSize
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        setAccessibilityLabel("Video annotation canvas")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var imageRect: CGRect {
        let scale = min(bounds.width / sourceSize.width, bounds.height / sourceSize.height)
        let size = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    func showFrame(_ image: CGImage, at time: TimeInterval) {
        sourceImage = image
        self.time = time
        refresh()
    }

    func refresh() {
        guard let image = sourceImage else { return }
        var visible = annotations.filter { time >= $0.start && time < $0.end }.map(\.annotation)
        if let live { visible.append(live) }
        renderedImage = Renderer.flatten(image: image, scale: CGFloat(image.width) / sourceSize.width,
            selection: CGRect(origin: .zero, size: sourceSize), annotations: visible)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard let image = renderedImage else { return }
        NSImage(cgImage: image, size: sourceSize).draw(in: imageRect, from: .zero,
            operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        if let selected = annotations.first(where: { $0.id == selectedID }),
           time >= selected.start, time < selected.end {
            let scale = imageRect.width / sourceSize.width
            let box = selected.annotation.dirtyBounds
            let rect = CGRect(x: imageRect.minX + box.minX * scale, y: imageRect.minY + box.minY * scale,
                              width: box.width * scale, height: box.height * scale)
            let path = NSBezierPath(rect: rect)
            path.setLineDash([4, 3], count: 2, phase: 0)
            path.lineWidth = 1
            NSColor.white.setStroke()
            path.stroke()
        }
    }

    private func sourcePoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        let scale = imageRect.width / sourceSize.width
        return CGPoint(x: min(sourceSize.width, max(0, (p.x - imageRect.minX) / scale)),
                       y: min(sourceSize.height, max(0, (p.y - imageRect.minY) / scale)))
    }

    override func mouseDown(with event: NSEvent) {
        commitTextEntry()
        guard imageRect.contains(convert(event.locationInWindow, from: nil)), sourceImage != nil else { return }
        onPause?()
        window?.makeFirstResponder(self)
        let point = sourcePoint(event)
        guard let tool else {
            let hit = annotations.reversed().first {
                time >= $0.start && time < $0.end && $0.annotation.dirtyBounds.contains(point)
            }
            onSelect?(hit?.id)
            return
        }
        if tool == .text { beginText(at: point); return }
        anchor = point
        points = [point]
        live = makeAnnotation(at: point, constrained: event.modifierFlags.contains(.shift))
        refresh()
    }

    override func mouseDragged(with event: NSEvent) {
        guard anchor != nil else { return }
        let point = sourcePoint(event)
        points.append(point)
        live = makeAnnotation(at: point, constrained: event.modifierFlags.contains(.shift))
        refresh()
    }

    override func mouseUp(with event: NSEvent) {
        guard anchor != nil else { return }
        if let live {
            // A click places a numbered step; other shapes need a visible extent.
            let hasExtent = points.dropFirst().contains {
                hypot($0.x - points[0].x, $0.y - points[0].y) >= 1
            }
            if tool == .step || hasExtent { onCommit?(live) }
        }
        live = nil
        anchor = nil
        points = []
        refresh()
    }

    private func makeAnnotation(at point: CGPoint, constrained: Bool) -> Annotation? {
        guard let start = anchor, let tool else { return nil }
        var end = point
        if constrained {
            let dx = point.x - start.x, dy = point.y - start.y
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            end = CGPoint(x: start.x + cos(angle) * hypot(dx, dy), y: start.y + sin(angle) * hypot(dx, dy))
        }
        let shape: Annotation.Shape
        switch tool {
        case .pen, .marker: shape = .stroke(points: points)
        case .line: shape = .line(from: start, to: end)
        case .arrow: shape = .arrow(from: start, to: end)
        case .rectangle: shape = .rectangle(CGRect(corner: start, corner: point))
        case .blur: shape = .blur(CGRect(corner: start, corner: point))
        case .pixelate: shape = .pixelate(CGRect(corner: start, corner: point))
        case .step:
            shape = .step(number: Annotation.nextStepNumber(in: annotations.map(\.annotation)), center: start)
        case .text: return nil
        }
        let scale = max(0.001, imageRect.width / sourceSize.width)
        return Annotation(shape: shape, color: color, lineWidth: lineWidth * tool.widthMultiplier / scale,
                          alpha: tool.strokeAlpha, fontSize: 24 / scale,
                          rasterScale: tool == .blur || tool == .pixelate ? 1 / scale : 1)
    }

    private func beginText(at point: CGPoint) {
        let scale = imageRect.width / sourceSize.width
        let origin = CGPoint(x: imageRect.minX + point.x * scale, y: imageRect.minY + point.y * scale)
        let entry = TextEntryView(origin: origin, color: color, fontSize: 24,
                                  maxWidth: imageRect.maxX - origin.x)
        textOrigin = CGPoint(x: point.x + entry.textContainerInset.width / scale,
                             y: point.y + entry.textContainerInset.height / scale)
        textFontSize = 24 / scale
        entry.onCommit = { [weak self] _ in self?.commitTextEntry() }
        entry.onCancel = { [weak self] in
            self?.textEntry?.removeFromSuperview()
            self?.textEntry = nil
            self?.window?.makeFirstResponder(self)
        }
        addSubview(entry)
        textEntry = entry
        window?.makeFirstResponder(entry)
    }

    func commitTextEntry() {
        guard let entry = textEntry else { return }
        let text = entry.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let textColor = entry.textColor ?? color
        entry.removeFromSuperview()
        textEntry = nil
        if !text.isEmpty {
            onCommit?(Annotation(shape: .text(text, origin: textOrigin), color: textColor, lineWidth: lineWidth,
                                 fontSize: textFontSize))
        }
        window?.makeFirstResponder(self)
    }
}
