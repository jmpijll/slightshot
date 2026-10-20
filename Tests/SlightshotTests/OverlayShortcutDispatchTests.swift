import AppKit
import Testing
@testable import Slightshot

/// The Edit menu swallows a matching key equivalent even when it cannot act, so the
/// overlay must claim its own ⌘ shortcuts during the window's key-equivalent pass.
@MainActor @Suite(.serialized)
struct OverlayShortcutDispatchTests {
    @Test func overlayWindowKeepsShortcutsWhileToolbarOrPaletteHasFocus() throws {
        let probe = try Probe()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 460),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = probe.view
        probe.view.frame = window.contentLayoutRect
        try probe.verify(in: window)
    }

    @Test func clipboardEditorKeepsShortcutsWhileToolbarOrPaletteHasFocus() throws {
        let probe = try Probe()
        let window = ClipboardEditorWindow(editor: probe.view)
        defer { window.close() }
        try probe.verify(in: window)
    }

    private final class Probe: OverlayViewDelegate {
        let view: OverlayView
        private var actions: [CaptureAction] = []
        private var cancels = 0

        init() throws {
            let context = try #require(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
            view = OverlayView(source: EditorImageSource(image: try #require(context.makeImage()), scale: 1))
            view.delegate = self
        }

        func verify(in window: NSWindow) throws {
            view.selectAll()
            let swatch = try #require(descendants(of: window).compactMap { $0 as? ColorSwatchButton }.first)
            swatch.performClick(nil)
            let slider = try #require(descendants(of: window).compactMap { $0 as? NSSlider }.first)
            let button = try #require(descendants(of: window).compactMap { $0 as? ToolbarButton }.first)

            for control in [slider, button] as [NSView] {
                #expect(window.makeFirstResponder(control), "\(type(of: control)) takes focus")
                for (key, expected) in [("c", CaptureAction.copy), ("s", .save), ("p", .print)] {
                    actions = []
                    #expect(window.performKeyEquivalent(with: try command(key, in: window)))
                    #expect(actions == [expected], "⌘\(key.uppercased()) from \(type(of: control))")
                }
                actions = []
                #expect(window.performKeyEquivalent(with: try command("s", shift: true, in: window)))
                #expect(actions == [.saveAs], "⇧⌘S from \(type(of: control))")
                cancels = 0
                #expect(window.performKeyEquivalent(with: try command("x", in: window)))
                #expect(cancels == 1, "⌘X from \(type(of: control))")
                for key in ["a", "z"] {
                    #expect(window.performKeyEquivalent(with: try command(key, in: window)),
                            "⌘\(key.uppercased()) from \(type(of: control))")
                }
                #expect(window.performKeyEquivalent(with: try command("z", shift: true, in: window)))
            }

            let tool = try #require(descendants(of: window).compactMap { $0 as? ToolbarButton }
                .first { $0.accessibilityLabel() == Tool.text.title })
            tool.performClick(nil)
            let point = CGPoint(x: 60, y: 60)
            view.mouseDown(with: try #require(NSEvent.mouseEvent(with: .leftMouseDown,
                location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
            #expect(window.firstResponder is TextEntryView)
            actions = []
            for key in ["a", "c", "x", "z"] {
                #expect(!window.performKeyEquivalent(with: try command(key, in: window)),
                        "⌘\(key.uppercased()) goes on to the Edit menu while the text box has focus")
            }
            #expect(actions.isEmpty)
        }

        private func command(_ key: String, shift: Bool = false, in window: NSWindow) throws -> NSEvent {
            let typed = shift ? key.uppercased() : key
            return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: shift ? [.command, .shift] : .command, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: typed,
                charactersIgnoringModifiers: typed, isARepeat: false, keyCode: 0))
        }

        private func descendants(of window: NSWindow) -> [NSView] {
            func walk(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + walk($0) } }
            return window.contentView.map(walk) ?? []
        }

        func overlayDidCancel(_ view: OverlayView) { cancels += 1 }
        func overlayDidTakeOver(_ view: OverlayView) {}
        func overlay(_ view: OverlayView, didComplete action: CaptureAction, image: CGImage) { actions.append(action) }
        func overlay(_ view: OverlayView, didRequestRecording selection: CGRect) {}
    }
}
