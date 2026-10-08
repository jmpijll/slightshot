import AppKit
import Testing
@testable import Slightshot

@MainActor
struct AnnotationRedoTests {
    @Test func shortcutsAndToolbarRestoreRasterStepsAndTextInOriginalOrder() throws {
        let editor = try Editor()
        defer { editor.window.close() }
        try editor.draw(.step, from: CGPoint(x: 42, y: 42))
        try editor.draw(.blur, from: CGPoint(x: 22, y: 22), to: CGPoint(x: 80, y: 70))
        try editor.draw(.pixelate, from: CGPoint(x: 30, y: 30), to: CGPoint(x: 90, y: 76))
        try editor.draw(.step, from: CGPoint(x: 98, y: 65))
        try editor.text("Restored", at: CGPoint(x: 32, y: 88))
        let original = try editor.export()
        #expect(!editor.redoButton.isEnabled)
        for _ in 0..<5 { try editor.key("z") }
        let empty = try editor.export()
        #expect(original != empty)
        #expect(editor.redoButton.isEnabled)
        for _ in 0..<4 { try editor.key("z", shift: true) }
        editor.redoButton.performClick(nil)
        #expect(try editor.export() == original)
        #expect(!editor.redoButton.isEnabled)
        try editor.key("z", shift: true)
        #expect(try editor.export() == original)
        try editor.draw(.step, from: CGPoint(x: 128, y: 55))
        #expect(editor.stepNumbers == [1, 2, 3])
        let withThirdStep = try editor.export()
        editor.view.undo()
        #expect(try editor.export() == original)
        editor.view.redo()
        #expect(try editor.export() == withThirdStep)
    }

    @Test func newDrawingAndCommittedTextDiscardRedoButCancelledDraftAndStyleChangesKeepIt() throws {
        let editor = try Editor()
        defer { editor.window.close() }
        try editor.draw(.step, from: CGPoint(x: 42, y: 42))
        try editor.draw(.step, from: CGPoint(x: 98, y: 65))
        editor.view.undo()
        try editor.choose(.text)
        editor.view.toolbarDidChangeColor(.blue)
        editor.view.toolbarDidChangeLineWidth(6)
        try editor.press(at: CGPoint(x: 32, y: 88))
        let entry = try #require(editor.view.subviews.compactMap { $0 as? TextEntryView }.first)
        #expect(!editor.redoButton.isEnabled)
        entry.string = "Uncommitted"
        let draft = try editor.draftText()
        editor.view.redo()
        #expect(entry.superview === editor.view)
        #expect(try editor.draftText() == draft)
        entry.onCancel?()
        #expect(editor.redoButton.isEnabled)
        editor.view.redo()
        #expect(!editor.redoButton.isEnabled)
        editor.view.undo()
        try editor.text("New text", at: CGPoint(x: 32, y: 88))
        #expect(!editor.redoButton.isEnabled)
        let newText = try editor.export()
        editor.view.redo()
        #expect(try editor.export() == newText)
        editor.view.undo()
        try editor.draw(.step, from: CGPoint(x: 70, y: 50))
        #expect(!editor.redoButton.isEnabled)
        #expect(editor.stepNumbers == [1, 2])
        let branched = try editor.export()
        editor.view.redo()
        #expect(try editor.export() == branched)
    }

    @Test func newSelectionClearsRedoAndEmptyHistoryIsHarmless() throws {
        let editor = try Editor()
        defer { editor.window.close() }
        editor.view.undo()
        editor.view.redo()
        try editor.draw(.step, from: CGPoint(x: 42, y: 42))
        editor.view.undo()
        editor.view.selectAll()
        #expect(!editor.redoButton.isEnabled)
        try editor.draw(.step, from: CGPoint(x: 42, y: 42))
        editor.view.undo()
        try editor.press(at: CGPoint(x: -10, y: -10))
        #expect(!editor.redoButton.isEnabled)
        editor.view.redo()
    }

    @Test func nativeTextUndoRedoDoesNotRestoreCommittedAnnotations() throws {
        let editor = try Editor()
        defer { editor.window.close() }
        try editor.draw(.step, from: CGPoint(x: 42, y: 42))
        editor.view.undo()
        try editor.choose(.text)
        try editor.press(at: CGPoint(x: 32, y: 88))
        let entry = try #require(editor.view.subviews.compactMap { $0 as? TextEntryView }.first)
        entry.insertText("draft", replacementRange: NSRange(location: 0, length: 0))
        _ = try #require(entry.undoManager)
        entry.keyDown(with: try editor.keyEvent("z"))
        #expect(entry.string.isEmpty)
        entry.keyDown(with: try editor.keyEvent("z", shift: true))
        #expect(entry.string == "draft")
        #expect(!editor.redoButton.isEnabled)
        entry.onCancel?()
        #expect(editor.redoButton.isEnabled)
        #expect(entry.superview == nil)
    }

    private final class Editor: OverlayViewDelegate {
        let window: NSWindow
        let view: OverlayView
        private var image: CGImage?
        var stepNumbers: [Int] {
            view.subviews.compactMap { $0 as? CanvasView }.first!.annotations.compactMap {
                if case .step(let number, _) = $0.shape { return number }
                return nil
            }
        }
        var redoButton: ToolbarButton {
            descendants(of: view).compactMap { $0 as? ToolbarButton }
                .first { $0.accessibilityLabel() == "Redo  ⇧⌘Z" }!
        }

        init() throws {
            let context = try #require(CGContext(data: nil, width: 160, height: 130, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            for x in 0..<160 {
                context.setFillColor(CGColor(red: CGFloat(x % 31) / 31, green: 0.2, blue: 0.4, alpha: 1))
                context.fill(CGRect(x: x, y: 0, width: 1, height: 130))
            }
            let screen = try #require(NSScreen.main)
            view = OverlayView(display: CapturedDisplay(screen: screen, displayID: screen.displayID,
                image: try #require(context.makeImage()), scale: 1))
            window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 160, height: 130),
                              styleMask: .borderless, backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = view
            view.frame = CGRect(x: 0, y: 0, width: 160, height: 130)
            view.delegate = self
            view.selectAll()
        }

        func choose(_ tool: Tool) throws {
            let button = try #require(descendants(of: view).compactMap { $0 as? ToolbarButton }
                .first { $0.accessibilityLabel() == tool.title })
            if !button.isSelectedItem { button.performClick(nil) }
        }

        func draw(_ tool: Tool, from start: CGPoint, to end: CGPoint? = nil) throws {
            try choose(tool)
            try press(at: start)
            if let end { view.mouseDragged(with: try mouse(.leftMouseDragged, at: end)) }
            view.mouseUp(with: try mouse(.leftMouseUp, at: end ?? start))
        }

        func text(_ value: String, at point: CGPoint) throws {
            try choose(.text)
            try press(at: point)
            let entry = try #require(view.subviews.compactMap { $0 as? TextEntryView }.first)
            entry.string = value
            view.commitTextEntry()
        }

        func press(at point: CGPoint) throws { view.mouseDown(with: try mouse(.leftMouseDown, at: point)) }

        func key(_ character: String, shift: Bool = false) throws {
            view.keyDown(with: try keyEvent(character, shift: shift))
        }

        func keyEvent(_ character: String, shift: Bool = false) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: shift ? [.command, .shift] : .command, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: false, keyCode: character == "z" ? 6 : 8))
        }

        func export() throws -> [UInt8] {
            try key("c")
            let image = try #require(image)
            let data = try #require(image.dataProvider?.data)
            let bytes = try #require(CFDataGetBytePtr(data))
            return Array(UnsafeBufferPointer(start: bytes, count: CFDataGetLength(data)))
        }

        func draftText() throws -> String {
            let entry = try #require(view.subviews.compactMap { $0 as? TextEntryView }.first)
            return entry.string
        }

        private func mouse(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
        }

        private func descendants(of view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants(of: $0) }
        }

        func overlayDidCancel(_ view: OverlayView) {}
        func overlayDidTakeOver(_ view: OverlayView) {}
        func overlay(_ view: OverlayView, didComplete action: CaptureAction, image: CGImage) { self.image = image }
        func overlay(_ view: OverlayView, didRequestRecording selection: CGRect) {}
    }
}
