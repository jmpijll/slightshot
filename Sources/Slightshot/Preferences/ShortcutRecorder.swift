import AppKit
import SwiftUI

/// Click, then press a combination. Escape clears it, Return leaves it unchanged.
final class ShortcutRecorderView: NSView {
    var combo: KeyCombo { didSet { needsDisplay = true } }
    var onChange: ((KeyCombo) -> Void)?

    private var recording = false { didSet { needsDisplay = true } }
    private var monitor: Any?

    init(combo: KeyCombo) {
        self.combo = combo
        super.init(frame: NSRect(x: 0, y: 0, width: 150, height: 24))
        wantsLayer = true
        layer?.cornerRadius = 6
        setAccessibilityRole(.button)
        setAccessibilityLabel("Keyboard shortcut")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }

    override func mouseDown(with event: NSEvent) {
        if recording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        recording = true
        window?.makeFirstResponder(self)
        // A local monitor beats `keyDown`, which never sees ⌘-combinations that
        // the main menu would otherwise swallow.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.recording else { return event }
            guard event.type == .keyDown else { return nil }

            if event.keyCode == 53 {           // Escape clears
                self.apply(.none)
                return nil
            }
            if event.keyCode == 36 {           // Return confirms without changing
                self.stopRecording()
                return nil
            }
            if let recorded = KeyCombo(event: event) {
                self.apply(recorded)
            } else {
                NSSound.beep()                 // modifier-less keys are rejected
            }
            return nil
        }
    }

    private func apply(_ newCombo: KeyCombo) {
        combo = newCombo
        onChange?(newCombo)
        stopRecording()
    }

    private func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return true
    }

    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = recording
            ? NSColor.controlAccentColor.withAlphaComponent(0.18)
            : NSColor.unemphasizedSelectedContentBackgroundColor
        background.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()

        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        border.lineWidth = 1
        border.stroke()

        let text = recording ? "Press a shortcut…" : combo.displayString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: recording ? .regular : .medium),
            .foregroundColor: recording ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        string.draw(at: CGPoint(x: (bounds.width - size.width) / 2,
                                y: (bounds.height - size.height) / 2))
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var combo: KeyCombo

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView(combo: combo)
        view.onChange = { combo = $0 }
        return view
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        if view.combo != combo { view.combo = combo }
    }
}
