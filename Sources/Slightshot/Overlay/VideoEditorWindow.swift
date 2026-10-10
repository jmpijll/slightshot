import AppKit
import AVFoundation
import CoreImage

/// The recording stays owned by its coordinator until Save succeeds or Discard is confirmed.
final class VideoEditorWindow: NSWindow, NSWindowDelegate {
    var onSave: (([VideoAnnotation]) -> Void)?
    var onDiscard: (() -> Void)?
    let canvas: VideoCanvasView
    private let duration: TimeInterval
    private let player: AVPlayer
    private let output: AVPlayerItemVideoOutput
    private let source: URL
    private let context = CIContext()
    private let scrubber = NSSlider()
    private let clock = NSTextField(labelWithString: "")
    private let play = NSButton(title: "Play", target: nil, action: nil)
    private let picker = NSPopUpButton()
    private let fromField = NSTextField()
    private let toField = NSTextField()
    private let range = VideoRangeControl()
    private let hint = NSTextField(labelWithString: "Pause to draw. Select a mark to set when it appears.")
    private var toolButtons: [Tool: ToolbarButton] = [:]
    private var undoButton: ToolbarButton?
    private var redoButton: ToolbarButton?
    private var deleteButton: NSButton?
    private var timer: Timer?
    private var seekTask: Task<Void, Never>?
    private var seekRevision = 0
    private var playbackRevision = 0
    private var isSeeking = false
    private var annotations: [VideoAnnotation] = []
    private var undoStates: [[VideoAnnotation]] = []
    private var redoStates: [[VideoAnnotation]] = []
    private var selectedID: UUID?

    init(source: URL, duration: TimeInterval, sourceSize: CGSize) {
        self.duration = duration
        self.source = source
        canvas = VideoCanvasView(sourceSize: sourceSize)
        let asset = AVURLAsset(url: source)
        let item = AVPlayerItem(asset: asset)
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: CVPixelBufferAttributes(
            pixelFormatTypes: [.init(rawValue: kCVPixelFormatType_32BGRA)]))
        output.suppressesPlayerRendering = true
        item.add(output)
        player = AVPlayer(playerItem: item)
        player.isMuted = true
        super.init(contentRect: CGRect(x: 0, y: 0, width: 1040, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        title = "Edit Recording"
        isReleasedWhenClosed = false
        minSize = CGSize(width: 720, height: 540)
        delegate = self
        buildContent()
        canvas.onPause = { [weak self] in self?.pause() }
        canvas.onCommit = { [weak self] annotation in self?.add(annotation) }
        canvas.onSelect = { [weak self] id in self?.select(id) }
        refreshControls()
        center()
        let tick = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderPlayback() }
        }
        timer = tick
        RunLoop.main.add(tick, forMode: .common)
        scheduleSeek(0)
    }

    private func buildContent() {
        guard let host = contentView else { return }
        let tools = makeTools()
        let transport = NSStackView(views: [play, scrubber, clock])
        transport.spacing = 12
        play.target = self
        play.action = #selector(togglePlayback)
        play.widthAnchor.constraint(equalToConstant: 64).isActive = true
        scrubber.minValue = 0
        scrubber.maxValue = duration
        scrubber.isContinuous = true
        scrubber.target = self
        scrubber.action = #selector(scrub)
        scrubber.setAccessibilityLabel("Video playhead")
        clock.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        clock.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let annotationControls = makeAnnotationControls()
        range.duration = duration
        range.onBeginChange = { [weak self] in
            guard let self else { return }
            self.canvas.commitTextEntry()
            self.pause()
            self.rememberChange()
        }
        range.onChange = { [weak self] start, end in self?.updateRange(start: start, end: end) }
        range.toolTip = "Drag the left and right handles to choose when the selected annotation appears."
        range.heightAnchor.constraint(equalToConstant: 36).isActive = true
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        let save = NSButton(title: "Save MP4…", target: self, action: #selector(saveRecording))
        save.bezelStyle = .rounded
        save.keyEquivalent = "s"
        save.keyEquivalentModifierMask = .command
        let discard = NSButton(title: "Discard…", target: self, action: #selector(discardRecording))
        discard.bezelStyle = .rounded
        let spacer = NSView()
        let footer = NSStackView(views: [hint, spacer, discard, save])
        footer.spacing = 12
        let column = NSStackView(views: [tools, canvas, transport, annotationControls, range, footer])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        column.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 20),
            column.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -20),
            column.topAnchor.constraint(equalTo: host.topAnchor, constant: 16),
            column.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -16),
            canvas.widthAnchor.constraint(equalTo: column.widthAnchor),
            canvas.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
            transport.widthAnchor.constraint(equalTo: column.widthAnchor),
            range.widthAnchor.constraint(equalTo: column.widthAnchor),
            footer.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
    }

    private func makeTools() -> NSView {
        let select = NSButton(title: "Select", target: self, action: #selector(selectTool))
        select.bezelStyle = .rounded
        select.toolTip = "Select an annotation to change its visible period or remove it."
        var buttons: [NSView] = []
        for tool in Tool.allCases {
            let button = ToolbarButton(icon: tool.icon, tooltip: tool.title) { [weak self] in
                self?.canvas.commitTextEntry()
                self?.setTool(tool)
            }
            buttons.append(button)
            toolButtons[tool] = button
        }
        let undo = ToolbarButton(icon: .undo, tooltip: "Undo (⌘Z)") { [weak self] in self?.performUndo() }
        let redo = ToolbarButton(icon: .redo, tooltip: "Redo (⌘⇧Z)") { [weak self] in self?.performRedo() }
        undoButton = undo
        redoButton = redo
        buttons += [ToolbarPanel.separator(orientation: .horizontal), undo, redo]
        let bar = ToolbarPanel(orientation: .horizontal, views: buttons)
        let color = NSColorWell()
        color.color = canvas.color
        color.target = self
        color.action = #selector(colorChanged)
        color.setAccessibilityLabel("Annotation colour")
        color.widthAnchor.constraint(equalToConstant: 40).isActive = true
        let thickness = NSSlider(value: 4, minValue: 1, maxValue: 12, target: self, action: #selector(widthChanged))
        thickness.setAccessibilityLabel("Annotation thickness")
        thickness.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let row = NSStackView(views: [select, bar, color, thickness])
        row.spacing = 10
        return row
    }

    private func makeAnnotationControls() -> NSView {
        picker.target = self
        picker.action = #selector(pickAnnotation)
        picker.setAccessibilityLabel("Selected annotation")
        picker.widthAnchor.constraint(equalToConstant: 210).isActive = true
        for field in [fromField, toField] {
            let formatter = NumberFormatter()
            formatter.minimum = 0
            formatter.maximum = NSNumber(value: duration)
            formatter.maximumFractionDigits = 2
            formatter.minimumFractionDigits = 2
            field.formatter = formatter
            field.target = self
            field.action = #selector(timeChanged(_:))
            field.widthAnchor.constraint(equalToConstant: 70).isActive = true
        }
        fromField.setAccessibilityLabel("Annotation start in seconds")
        toField.setAccessibilityLabel("Annotation end in seconds")
        let whole = NSButton(title: "Whole video", target: self, action: #selector(wholeVideo))
        let delete = NSButton(title: "Delete", target: self, action: #selector(deleteAnnotation))
        deleteButton = delete
        let row = NSStackView(views: [picker, NSTextField(labelWithString: "From"), fromField,
            NSTextField(labelWithString: "to"), toField, NSTextField(labelWithString: "seconds"), whole, delete])
        row.spacing = 8
        return row
    }

    private func setTool(_ tool: Tool?) {
        pause()
        canvas.tool = tool
        for (value, button) in toolButtons { button.isSelectedItem = value == tool }
        makeFirstResponder(canvas)
    }

    @objc private func selectTool() { canvas.commitTextEntry(); setTool(nil) }
    @objc private func colorChanged(_ sender: NSColorWell) { canvas.color = sender.color }
    @objc private func widthChanged(_ sender: NSSlider) { canvas.lineWidth = sender.doubleValue }
    @objc private func scrub() { canvas.commitTextEntry(); pause(); scheduleSeek(scrubber.doubleValue) }

    @objc private func togglePlayback() {
        canvas.commitTextEntry()
        if player.rate > 0 { pause(); return }
        if scrubber.doubleValue >= duration - 0.05 {
            let revision = playbackRevision
            seekTask?.cancel()
            seekTask = Task { [weak self] in
                guard let self else { return }
                await self.seek(to: 0)
                guard !Task.isCancelled, revision == self.playbackRevision else { return }
                self.player.play()
                self.play.title = "Pause"
            }
        } else { player.play(); play.title = "Pause" }
    }

    private func pause() { playbackRevision += 1; player.pause(); play.title = "Play" }

    private func scheduleSeek(_ time: TimeInterval) {
        seekTask?.cancel()
        seekTask = Task { [weak self] in await self?.seek(to: time) }
    }

    private func seek(to time: TimeInterval) async {
        guard !Task.isCancelled else { return }
        seekRevision += 1
        let revision = seekRevision
        isSeeking = true
        let target = min(max(0, time), max(0, duration - 1.0 / 600))
        let cmTime = CMTime(seconds: target, preferredTimescale: 600)
        _ = await player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        do {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 960, height: 960)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let frame = try await generator.image(at: cmTime)
            guard !Task.isCancelled, revision == seekRevision else { return }
            canvas.showFrame(frame.image, at: target)
            updatePlayhead(target)
        } catch {
            guard !Task.isCancelled, revision == seekRevision else { return }
            hint.stringValue = "The video preview could not be loaded. You can retry or save the recording."
        }
        if revision == seekRevision { isSeeking = false }
    }

    private func renderPlayback() {
        guard !isSeeking else { return }
        guard player.rate > 0 else {
            if play.title == "Pause" { pause(); updatePlayhead(min(duration, player.currentTime().seconds)) }
            return
        }
        let time = player.currentTime()
        guard time.seconds.isFinite else { return }
        if let buffer = output.pixelBufferAndDisplayTime(forItemTime: time).pixelBuffer {
            let frame = buffer.withUnsafeBuffer { pixel in
                let image = CIImage(cvPixelBuffer: pixel)
                let scale = min(1, 960 / image.extent.width)
                let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                return context.createCGImage(small, from: small.extent)
            }
            if let frame {
                canvas.showFrame(frame, at: time.seconds)
            }
        }
        updatePlayhead(time.seconds)
        if time.seconds >= duration - 0.03 { pause() }
    }

    private func updatePlayhead(_ time: TimeInterval) {
        scrubber.doubleValue = time
        clock.stringValue = String(format: "%.2f / %.2f s", time, duration)
        range.playhead = time
        range.needsDisplay = true
    }

    private func rememberChange() {
        undoStates.append(annotations)
        redoStates.removeAll()
    }

    private func add(_ annotation: Annotation) {
        rememberChange()
        annotations.append(VideoAnnotation(annotation: annotation, start: 0, end: duration))
        selectedID = annotation.id
        refreshControls()
    }

    private func select(_ id: UUID?) { canvas.commitTextEntry(); selectedID = id; refreshControls() }

    @objc private func pickAnnotation() {
        let index = picker.indexOfSelectedItem
        guard annotations.indices.contains(index) else { return }
        select(annotations[index].id)
    }

    @objc private func timeChanged(_ sender: NSTextField) {
        let enteredTime = sender.doubleValue
        canvas.commitTextEntry()
        rememberChange()
        // Committing a caption selects it and refreshes both fields. Preserve
        // the entered endpoint, while its other endpoint comes from that caption.
        updateRange(start: sender === fromField ? enteredTime : fromField.doubleValue,
                    end: sender === toField ? enteredTime : toField.doubleValue)
    }

    private func updateRange(start: TimeInterval, end: TimeInterval) {
        guard let index = annotations.firstIndex(where: { $0.id == selectedID }) else { return }
        let gap = min(1.0 / 30, duration)
        let safeStart = min(max(0, start), max(0, duration - gap))
        let safeEnd = min(duration, max(safeStart + gap, end))
        annotations[index].setRange(start: safeStart, end: safeEnd, duration: duration)
        refreshControls()
    }

    @objc private func wholeVideo() {
        canvas.commitTextEntry()
        guard selectedID != nil else { return }
        rememberChange()
        updateRange(start: 0, end: duration)
    }

    @objc private func deleteAnnotation() {
        canvas.commitTextEntry()
        guard selectedID != nil else { return }
        rememberChange()
        annotations.removeAll { $0.id == selectedID }
        selectedID = annotations.last?.id
        refreshControls()
    }

    private func performUndo() {
        canvas.commitTextEntry()
        guard let previous = undoStates.popLast() else { return }
        redoStates.append(annotations)
        annotations = previous
        refreshControls()
    }

    private func performRedo() {
        guard let next = redoStates.popLast() else { return }
        undoStates.append(annotations)
        annotations = next
        refreshControls()
    }

    private func refreshControls() {
        if let id = selectedID, !annotations.contains(where: { $0.id == id }) { selectedID = annotations.last?.id }
        picker.removeAllItems()
        for (index, value) in annotations.enumerated() {
            picker.addItem(withTitle: "\(index + 1). \(value.annotation.videoToolTitle)")
        }
        if annotations.isEmpty { picker.addItem(withTitle: "No annotations yet") }
        let selected = annotations.first { $0.id == selectedID }
        if let index = annotations.firstIndex(where: { $0.id == selectedID }) { picker.selectItem(at: index) }
        picker.isEnabled = !annotations.isEmpty
        fromField.isEnabled = selected != nil
        toField.isEnabled = selected != nil
        deleteButton?.isEnabled = selected != nil
        fromField.doubleValue = selected?.start ?? 0
        toField.doubleValue = selected?.end ?? duration
        range.isEnabled = selected != nil
        range.start = selected?.start ?? 0
        range.end = selected?.end ?? duration
        undoButton?.isEnabled = !undoStates.isEmpty
        redoButton?.isEnabled = !redoStates.isEmpty
        canvas.annotations = annotations
        canvas.selectedID = selectedID
        canvas.refresh()
    }

    @objc private func saveRecording() { canvas.commitTextEntry(); pause(); onSave?(annotations) }
    @objc private func discardRecording() { pause(); onDiscard?() }

    func windowShouldClose(_ sender: NSWindow) -> Bool { discardRecording(); return false }

    override func close() {
        pause()
        timer?.invalidate()
        timer = nil
        seekTask?.cancel()
        player.replaceCurrentItem(with: nil)
        super.close()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if firstResponder is NSTextView { return super.performKeyEquivalent(with: event) }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" {
            if event.modifierFlags.contains(.shift) { performRedo() } else { performUndo() }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: togglePlayback()
        case 51, 117: deleteAnnotation()
        case 53: selectTool()
        default: super.keyDown(with: event)
        }
    }

    // Review fixtures drive the same commit, selection, timing and history paths as native controls.
    func reviewAddAnnotation(_ value: VideoAnnotation) {
        add(value.annotation)
        updateRange(start: value.start, end: value.end)
    }
    var reviewCurrentTime: TimeInterval { canvas.time }

    func reviewSeek(to time: TimeInterval) async {
        seekTask?.cancel()
        seekTask = nil
        pause()
        await seek(to: time)
    }
    func reviewSelectAnnotation(index: Int) {
        guard annotations.indices.contains(index) else { return }
        select(annotations[index].id)
    }
    func reviewSetRange(start: TimeInterval, end: TimeInterval) {
        rememberChange(); updateRange(start: start, end: end)
    }
    func reviewUndo() { performUndo() }
    func reviewRedo() { performRedo() }
}

private extension Annotation {
    var videoToolTitle: String {
        switch shape {
        case .stroke: "Drawing"
        case .line: "Line"
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .text: "Text"
        case .blur: "Blur"
        case .pixelate: "Pixelate"
        case .step: "Numbered step"
        }
    }
}
