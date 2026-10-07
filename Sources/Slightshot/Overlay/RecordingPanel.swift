import AppKit

/// The same dark, compact toolbar as the selection UI, kept out of the video by
/// the stream's application filter. It floats without taking keyboard focus.
final class RecordingPanel: NSPanel {
    private let elapsed = NSTextField(labelWithString: "Starting…")
    private let stopButton: ToolbarButton
    private var timer: Timer?

    init(screen: NSScreen, selection: CGRect, onStop: @escaping () -> Void) {
        stopButton = ToolbarButton(symbol: "stop.fill", tooltip: "Stop recording", onClick: onStop)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        setAccessibilityLabel("Screen recording")

        elapsed.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        elapsed.textColor = .white
        elapsed.alignment = .center
        elapsed.widthAnchor.constraint(equalToConstant: 72).isActive = true
        stopButton.isSelectedItem = true
        stopButton.isEnabled = false
        let toolbar = ToolbarPanel(orientation: .horizontal, views: [elapsed, stopButton])
        contentView = toolbar
        let size = toolbar.fittingSize
        let displayBounds = CGRect(origin: .zero, size: screen.frame.size)
        let x = min(max(4, selection.maxX - size.width), displayBounds.maxX - size.width - 4)
        var y = selection.maxY + 8
        if y + size.height > displayBounds.maxY - 4 { y = selection.minY - size.height - 8 }
        if y < 4 { y = max(4, selection.maxY - size.height - 8) }
        setFrame(CGRect(x: screen.frame.minX + x, y: screen.frame.maxY - y - size.height,
                        width: size.width, height: size.height), display: false)
    }

    func started(duration: @escaping @MainActor @Sendable () -> TimeInterval) {
        stopButton.isEnabled = true
        updateDuration(duration())
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateDuration(duration()) }
        }
    }

    private func updateDuration(_ duration: TimeInterval) {
        let seconds = duration.isFinite ? max(0, Int(duration)) : 0
        elapsed.stringValue = String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    override func close() {
        timer?.invalidate()
        timer = nil
        super.close()
    }
}

/// Appears only after Stop, inside the standard save panel.
final class RecordingQualityView: NSView {
    private let slider: NSSlider
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let sourceSize: CGSize

    var quality: RecordingQuality { RecordingQuality(rawValue: Int(slider.doubleValue.rounded())) ?? .balanced }

    init(quality: RecordingQuality, sourceSize: CGSize) {
        slider = NSSlider(value: Double(quality.rawValue), minValue: 0, maxValue: 2, target: nil, action: nil)
        self.sourceSize = sourceSize
        super.init(frame: CGRect(x: 0, y: 0, width: 350, height: 112))
        slider.numberOfTickMarks = 3
        slider.allowsTickMarkValuesOnly = true
        slider.target = self
        slider.action = #selector(changed)
        slider.setAccessibilityLabel("Recording compression quality")
        slider.toolTip = "Smaller, faster exports on the left; higher quality on the right."
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.usesSingleLineMode = false
        detailLabel.maximumNumberOfLines = 2
        detailLabel.lineBreakMode = .byWordWrapping
        let small = NSTextField(labelWithString: "Small & fast")
        let high = NSTextField(labelWithString: "High quality")
        small.font = .systemFont(ofSize: 11)
        high.font = .systemFont(ofSize: 11)
        let labels = NSStackView(views: [small, NSView(), high])
        labels.distribution = .fill
        let stack = NSStackView(views: [titleLabel, slider, labels, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            slider.widthAnchor.constraint(equalTo: stack.widthAnchor),
            labels.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        changed()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func changed() {
        titleLabel.stringValue = quality.title
        detailLabel.stringValue = quality.detail(for: sourceSize)
        slider.setAccessibilityValue(quality.title)
    }
}

final class RecordingExportPanel: NSPanel {
    init(onCancel: @escaping () -> Void) {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 300, height: 90),
                   styleMask: [.titled], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        title = "Saving recording…"
        level = .floating
        let progress = NSProgressIndicator()
        progress.style = .bar
        progress.isIndeterminate = true
        progress.startAnimation(nil)
        let cancel = NSButton(title: "Cancel", target: nil, action: nil)
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let action = CancelAction(onCancel)
        cancel.target = action
        cancel.action = #selector(CancelAction.cancel)
        // NSControl's target is weak; retain it for the panel's lifetime.
        retainedAction = action
        let stack = NSStackView(views: [progress, cancel])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView!.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView!.trailingAnchor, constant: -20),
            stack.centerYAnchor.constraint(equalTo: contentView!.centerYAnchor),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        center()
    }

    private var retainedAction: CancelAction?

    private final class CancelAction: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func cancel() { action() }
    }
}
