import AppKit
import SwiftUI

/// Click, then press a combination. Escape clears it, Return leaves it unchanged.
/// Global shortcuts are suspended while it listens.
final class ShortcutRecorderView: NSView {
    var combo: KeyCombo { didSet { needsDisplay = true } }
    /// Returns false to refuse a combination and keep listening.
    var onRecord: ((KeyCombo) -> Bool)?

    private var recording = false { didSet { needsDisplay = true } }
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?

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
        // Becoming first responder stops any other recorder, which resumes hotkeys.
        window?.makeFirstResponder(self)
        recording = true
        HotKeyCenter.shared.setSuspended(true)
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopRecording() }
        }
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
            self.apply(KeyCombo(event: event))
            return nil
        }
    }

    private func apply(_ newCombo: KeyCombo) {
        guard onRecord?(newCombo) ?? true else {
            NSSound.beep()
            return
        }
        combo = newCombo
        stopRecording()
    }

    private func stopRecording() {
        guard recording else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        HotKeyCenter.shared.setSuspended(false)
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return true
    }

    isolated deinit {
        stopRecording()
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
    let combo: KeyCombo
    let onRecord: (KeyCombo) -> Bool

    func makeNSView(context: Context) -> ShortcutRecorderView {
        ShortcutRecorderView(combo: combo)
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        view.onRecord = onRecord
        if view.combo != combo { view.combo = combo }
    }
}
