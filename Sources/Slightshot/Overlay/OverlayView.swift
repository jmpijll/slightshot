import AppKit

nonisolated enum CaptureAction: Sendable {
    case copy, save, saveAs, print
}

@MainActor
protocol OverlayViewDelegate: AnyObject {
    func overlayDidCancel(_ view: OverlayView)
    func overlayDidTakeOver(_ view: OverlayView)
    func overlay(_ view: OverlayView, didComplete action: CaptureAction, image: CGImage)
}

/// The interactive capture surface for one display.
///
/// Coordinates throughout are *flipped display points* (origin top-left), which
/// is the same space `Annotation` and `Renderer` use, so nothing has to be
/// converted between drawing on screen and writing the file.
final class OverlayView: NSView {
    let display: CapturedDisplay
    weak var delegate: OverlayViewDelegate?

    // MARK: Subviews

    private let screenshotView: ScreenshotView
    private let dimView = DimView()
    private let canvas = CanvasView()
    private var magnifier: MagnifierView?
    private var textEntry: TextEntryView?
    private lazy var toolbars: ToolbarController = {
        let controller = ToolbarController(host: self, color: color, lineWidth: lineWidth)
        controller.delegate = self
        return controller
    }()

    // MARK: Editing state

    private var selection: CGRect? {
        didSet {
            canvas.selection = selection
            dimView.update(hole: selection)
            layoutToolbars()
        }
    }
    private var annotations: [Annotation] = [] { didSet { canvas.annotations = annotations } }
    private var activeTool: Tool? { toolbars.activeTool }

    private var color: NSColor
    private var lineWidth: CGFloat
    private var fontSize: CGFloat

    private enum DragState {
        case none
        case newSelection(anchor: CGPoint)
        case moveSelection(grabOffset: CGPoint)
        case resizeSelection(SelectionHandle)
        case drawing(start: CGPoint, points: [CGPoint])

        /// Toolbars stay hidden while the initial rectangle is still being dragged out.
        var isNotNewSelection: Bool {
            if case .newSelection = self { return false }
            return true
        }
    }
    private var drag: DragState = .none
    private var copyOnRelease = false

    // MARK: - Init

    init(display: CapturedDisplay) {
        self.display = display
        let settings = Settings.shared
        self.color = settings.annotationColor
        self.lineWidth = settings.lineWidth
        self.fontSize = settings.fontSize
        self.screenshotView = ScreenshotView(image: display.image,
                                             frame: NSRect(origin: .zero, size: display.frame.size))
        super.init(frame: NSRect(origin: .zero, size: display.frame.size))

        wantsLayer = true
        autoresizesSubviews = false

        screenshotView.frame = bounds
        dimView.frame = bounds
        dimView.opacity = settings.dimOpacity
        canvas.frame = bounds
        canvas.accent = color
        canvas.showDimensions = settings.showDimensions

        addSubview(screenshotView)
        addSubview(dimView)
        addSubview(canvas)
        dimView.update(hole: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        updateTrackingAreas()
        window?.makeFirstResponder(self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    // MARK: - Chrome visibility

    /// Shows the "drag to select" hint only on the display the pointer is on.
    func prepare(isUnderMouse: Bool) {
        canvas.showHint = isUnderMouse
        if isUnderMouse {
            updateMagnifier(at: convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil))
        }
    }

    /// Called when the user starts working on a different display.
    func relinquish() {
        hideMagnifier()
        canvas.showHint = false
    }

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    // MARK: - Mouse

    override func mouseEntered(with event: NSEvent) {
        if selection == nil { canvas.showHint = true }
        updateMagnifier(at: location(of: event))
    }

    override func mouseExited(with event: NSEvent) {
        hideMagnifier()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = location(of: event)
        updateMagnifier(at: point)
        updateCursor(at: point)
    }

    override func mouseDown(with event: NSEvent) {
        delegate?.overlayDidTakeOver(self)
        canvas.showHint = false
        commitTextEntry()

        let point = location(of: event)

        if event.clickCount == 2, let selection, selection.contains(point) {
            performDefaultAction()
            return
        }

        if let selection {
            if let handle = SelectionHandle.hit(point, in: selection) {
                drag = .resizeSelection(handle)
                return
            }
            if let tool = activeTool, selection.contains(point) {
                if tool == .text {
                    beginTextEntry(at: point)
                } else {
                    drag = .drawing(start: point, points: [point])
                }
                return
            }
            if selection.contains(point) {
                drag = .moveSelection(grabOffset: CGPoint(x: point.x - selection.minX,
                                                          y: point.y - selection.minY))
                return
            }
        }

        // Anywhere else: start a fresh selection.
        annotations.removeAll()
        copyOnRelease = event.modifierFlags.contains(.command)
        drag = .newSelection(anchor: point)
        self.selection = CGRect(corner: point, corner: point)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = clampToBounds(location(of: event))

        switch drag {
        case .none:
            break

        case .newSelection(let anchor):
            var rect = CGRect(corner: anchor, corner: point)
            if event.modifierFlags.contains(.shift) { rect = squared(rect, from: anchor, to: point) }
            selection = rect
            updateMagnifier(at: point)

        case .moveSelection(let grabOffset):
            guard let current = selection else { break }
            var origin = CGPoint(x: point.x - grabOffset.x, y: point.y - grabOffset.y)
            origin.x = min(max(0, origin.x), bounds.width - current.width)
            origin.y = min(max(0, origin.y), bounds.height - current.height)
            selection = CGRect(origin: origin, size: current.size)

        case .resizeSelection(let handle):
            guard let current = selection else { break }
            selection = handle.resized(current, to: point).clamped(to: bounds)
            updateMagnifier(at: point)

        case .drawing(let start, var points):
            guard let selection else { break }
            let confined = CGPoint(x: min(max(selection.minX, point.x), selection.maxX),
                                   y: min(max(selection.minY, point.y), selection.maxY))
            points.append(confined)
            drag = .drawing(start: start, points: points)
            canvas.liveAnnotation = makeAnnotation(start: start, current: confined, points: points,
                                                   constrained: event.modifierFlags.contains(.shift))
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .drawing:
            if let live = canvas.liveAnnotation {
                annotations.append(live)
                canvas.liveAnnotation = nil
            }
        case .newSelection:
            // A click without a drag means "no selection yet", not a 1×1 capture.
            if let selection, selection.width < 4 || selection.height < 4 {
                self.selection = nil
                canvas.showHint = true
            } else if copyOnRelease {
                drag = .none
                perform(.copy)
                return
            }
        default:
            break
        }
        drag = .none
        copyOnRelease = false
        layoutToolbars()
        if selection != nil { toolbars.restoreRememberedTool() }
        updateCursor(at: location(of: event))
    }

    override func rightMouseDown(with event: NSEvent) {
        delegate?.overlayDidCancel(self)
    }

    private func clampToBounds(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, point.x), bounds.width),
                y: min(max(0, point.y), bounds.height))
    }

    private func squared(_ rect: CGRect, from anchor: CGPoint, to point: CGPoint) -> CGRect {
        let side = max(abs(point.x - anchor.x), abs(point.y - anchor.y))
        let end = CGPoint(x: anchor.x + (point.x < anchor.x ? -side : side),
                          y: anchor.y + (point.y < anchor.y ? -side : side))
        return CGRect(corner: anchor, corner: end).clamped(to: bounds)
    }

    private func updateCursor(at point: CGPoint) {
        guard let selection else { NSCursor.crosshair.set(); return }
        if let handle = SelectionHandle.hit(point, in: selection) {
            handle.cursor.set()
        } else if activeTool != nil, selection.contains(point) {
            NSCursor.crosshair.set()
        } else if selection.contains(point) {
            NSCursor.openHand.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    // MARK: - Annotations

    private func makeAnnotation(start: CGPoint, current: CGPoint, points: [CGPoint], constrained: Bool) -> Annotation? {
        guard let tool = activeTool else { return nil }
        let end = constrained ? axisLocked(from: start, to: current) : current
        let width = lineWidth * tool.widthMultiplier

        let shape: Annotation.Shape
        switch tool {
        case .pen, .marker: shape = .stroke(points: points)
        case .line: shape = .line(from: start, to: end)
        case .arrow: shape = .arrow(from: start, to: end)
        case .rectangle: shape = .rectangle(CGRect(corner: start, corner: end))
        case .text: return nil
        }
        return Annotation(shape: shape, color: color, lineWidth: width,
                          alpha: tool.strokeAlpha, fontSize: fontSize)
    }

    /// Shift-constrains a line to the nearest 45° increment.
    private func axisLocked(from start: CGPoint, to end: CGPoint) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let length = hypot(dx, dy)
        return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
    }

    func undo() {
        if textEntry != nil { cancelTextEntry(); return }
        guard !annotations.isEmpty else { return }
        annotations.removeLast()
    }

    // MARK: - Text tool

    private func beginTextEntry(at point: CGPoint) {
        guard let selection else { return }
        let entry = TextEntryView(origin: point, color: color, fontSize: fontSize,
                                  maxWidth: max(80, selection.maxX - point.x))
        entry.onCommit = { [weak self] text in self?.finishTextEntry(with: text) }
        entry.onCancel = { [weak self] in self?.cancelTextEntry() }
        addSubview(entry)
        textEntry = entry
        window?.makeFirstResponder(entry)
    }

    /// Commits any open text field. Called before every action so typed text is
    /// never silently lost.
    func commitTextEntry() {
        guard let entry = textEntry else { return }
        finishTextEntry(with: entry.string)
    }

    private func finishTextEntry(with text: String) {
        guard let entry = textEntry else { return }
        let origin = CGPoint(x: entry.frame.minX + entry.textContainerInset.width,
                             y: entry.frame.minY + entry.textContainerInset.height)
        entry.removeFromSuperview()
        textEntry = nil
        window?.makeFirstResponder(self)

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        annotations.append(Annotation(shape: .text(text, origin: origin), color: color,
                                      lineWidth: lineWidth, alpha: 1, fontSize: fontSize))
    }

    private func cancelTextEntry() {
        textEntry?.removeFromSuperview()
        textEntry = nil
        window?.makeFirstResponder(self)
    }

    // MARK: - Magnifier

    private func updateMagnifier(at point: CGPoint) {
        guard Settings.shared.showMagnifier, selection == nil || isDraggingSelection else {
            hideMagnifier()
            return
        }

        let loupe: MagnifierView
        if let existing = magnifier {
            loupe = existing
        } else {
            loupe = MagnifierView(display: display)
            loupe.accentColor = color
            addSubview(loupe)
            magnifier = loupe
        }

        loupe.move(to: point)

        // Sits below-right of the crosshair, flipping near the display edges.
        let size = MagnifierView.totalSize
        var origin = CGPoint(x: point.x + 18, y: point.y + 18)
        if origin.x + size.width > bounds.maxX - 6 { origin.x = point.x - 18 - size.width }
        if origin.y + size.height > bounds.maxY - 6 { origin.y = point.y - 18 - size.height }
        origin.x = min(max(6, origin.x), bounds.maxX - size.width - 6)
        origin.y = min(max(6, origin.y), bounds.maxY - size.height - 6)
        loupe.setFrameOrigin(origin)
    }

    private var isDraggingSelection: Bool {
        switch drag {
        case .newSelection, .resizeSelection: true
        default: false
        }
    }

    private func hideMagnifier() {
        magnifier?.removeFromSuperview()
        magnifier = nil
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)

        if event.keyCode == 53 {  // Escape
            delegate?.overlayDidCancel(self)
            return
        }

        if command, let characters = event.charactersIgnoringModifiers?.lowercased() {
            switch characters {
            case "a": selectAll(); return
            case "c": perform(.copy); return
            case "s": perform(shift ? .saveAs : .save); return
            case "p": perform(.print); return
            case "z": undo(); return
            case "x": delegate?.overlayDidCancel(self); return
            default: break
            }
        }

        switch event.keyCode {
        case 36, 76:  // Return / Enter
            performDefaultAction()
        case 123: nudge(dx: shift ? -10 : -1, dy: 0)
        case 124: nudge(dx: shift ? 10 : 1, dy: 0)
        case 126: nudge(dx: 0, dy: shift ? -10 : -1)
        case 125: nudge(dx: 0, dy: shift ? 10 : 1)
        default:
            break
        }
    }

    private func nudge(dx: CGFloat, dy: CGFloat) {
        guard let current = selection else { return }
        var origin = CGPoint(x: current.minX + dx, y: current.minY + dy)
        origin.x = min(max(0, origin.x), bounds.width - current.width)
        origin.y = min(max(0, origin.y), bounds.height - current.height)
        selection = CGRect(origin: origin, size: current.size)
    }

    func selectAll() {
        canvas.showHint = false
        selection = bounds
    }

    // MARK: - Actions

    private func performDefaultAction() {
        switch Settings.shared.defaultAction {
        case .copy: perform(.copy)
        case .save: perform(.save)
        case .stayOpen: break
        }
    }

    private func perform(_ action: CaptureAction) {
        commitTextEntry()
        guard let selection, selection.width >= 1, selection.height >= 1 else { return }
        hideMagnifier()
        guard let image = Renderer.flatten(display: display, selection: selection, annotations: annotations) else {
            OutputService.presentError("Slightshot could not render the selection.")
            return
        }
        delegate?.overlay(self, didComplete: action, image: image)
    }

    // MARK: - Toolbars

    private func layoutToolbars() {
        toolbars.layout(around: selection, in: bounds, visible: drag.isNotNewSelection)
    }
}

// MARK: - ToolbarControllerDelegate

extension OverlayView: ToolbarControllerDelegate {
    func toolbarDidChangeTool(_ tool: Tool?) {
        commitTextEntry()
        hideMagnifier()
    }

    func toolbarDidChangeColor(_ newColor: NSColor) {
        color = newColor
        canvas.accent = newColor
        magnifier?.accentColor = newColor
    }

    func toolbarDidChangeLineWidth(_ width: CGFloat) {
        lineWidth = width
    }

    func toolbarDidRequestUndo() {
        undo()
    }

    func toolbarDidRequest(_ action: CaptureAction) {
        perform(action)
    }

    func toolbarDidRequestClose() {
        delegate?.overlayDidCancel(self)
    }
}
