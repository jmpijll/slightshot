import AppKit
import AVFoundation
import Testing
@testable import Slightshot

@MainActor @Suite(.serialized)
struct VideoTrimEditorTests {
    @Test func saveShortcutAndQuitSaveIncludeATypedTrimTime() async throws {
        let editor = try await Editor()
        editor.type("1\(decimal)50", into: editor.trimStart)
        #expect(editor.window.performKeyEquivalent(with: try key("s", keyCode: 1)))
        #expect(editor.saved?.trim == VideoTrim(start: 1.5, end: 2, recording: 2))

        editor.type("1.75", into: editor.trimEnd)
        editor.window.saveRecording()
        #expect(editor.saved?.trim == VideoTrim(start: 1.5, end: 1.75, recording: 2))

        editor.type("0\(decimal)25", into: editor.trimStart)
        editor.window.makeFirstResponder(editor.window.canvas)
        #expect(editor.window.reviewTrim.start == 0.25, "Focus loss commits a typed time.")
    }

    @Test func typedTimesMoveOnlyTheirEdgeRoundAndRevertInvalidText() async throws {
        let editor = try await Editor()
        editor.commit("1", into: editor.trimEnd)
        editor.commit("1.5", into: editor.trimStart)
        let trim = editor.window.reviewTrim
        #expect(trim.end == 1, "A typed start past the end must not move the end.")
        #expect(abs(trim.start - (1 - VideoTrim.minimumLength)) < 1e-9)
        editor.commit("2.5", into: editor.trimEnd)
        #expect(editor.window.reviewTrim.end == 2, "A typed end past the recording stops at its end.")
        editor.commit("0.123", into: editor.trimStart)
        #expect(editor.window.reviewTrim.start == 0.12)
        editor.commit("abc", into: editor.trimStart)
        #expect(editor.window.reviewTrim.start == 0.12)
        #expect(editor.trimStart.stringValue == VideoTimeText.string(0.12))
        editor.commit(VideoTimeText.string(0.12), into: editor.trimStart)

        let undoSteps: [VideoTrim] = [
            VideoTrim(start: 1 - VideoTrim.minimumLength, end: 2, recording: 2),
            VideoTrim(start: 1 - VideoTrim.minimumLength, end: 1, recording: 2),
            VideoTrim(start: 0, end: 1, recording: 2),
            .whole(2),
        ]
        for expected in undoSteps {
            editor.window.reviewUndo()
            #expect(editor.window.reviewTrim == expected)
        }
    }

    @Test func handleClicksThatChangeNothingKeepRedo() async throws {
        let editor = try await Editor()
        editor.commit("1.5", into: editor.trimEnd)
        editor.window.reviewUndo()
        #expect(editor.window.reviewTrim.isWhole(of: 2))
        try editor.drag(editor.handles, through: [0])
        try editor.drag(editor.handles, through: [2])
        editor.window.reviewRedo()
        #expect(editor.window.reviewTrim.end == 1.5, "A stationary click must not clear Redo.")

        try editor.drag(editor.handles, through: [0, 0.4, 0.5])
        #expect(editor.window.reviewTrim.start == 0.5)
        editor.window.reviewUndo()
        #expect(editor.window.reviewTrim == VideoTrim(start: 0, end: 1.5, recording: 2), "One drag is one step.")

        let fractional = try await Editor(frameCount: 61)
        let duration = 61.0 / 30
        fractional.commit("0.5", into: fractional.trimStart)
        fractional.window.reviewUndo()
        try fractional.drag(fractional.handles, through: [0])
        #expect(fractional.window.reviewTrim == .whole(duration), "A click must preserve the exact recording end.")
        fractional.window.reviewRedo()
        #expect(fractional.window.reviewTrim == VideoTrim(start: 0.5, end: duration, recording: duration))
        try fractional.drag(fractional.handles, through: [0.5, 0.7])
        #expect(fractional.window.reviewTrim.start == 0.7)
        #expect(fractional.window.reviewTrim.end == duration, "Dragging start never rounds the fixed end.")
    }

    @Test func seekingUpdatesTheTrimTimelinePlayhead() async throws {
        let editor = try await Editor()
        await editor.window.reviewSeek(to: 1)
        #expect(editor.handles.playhead == 1)
    }

    @Test func undoReplacesAPendingSeekOutsideTheRestoredTrim() async throws {
        let editor = try await Editor()
        editor.commit("0.5", into: editor.trimStart)
        editor.commit("1.5", into: editor.trimEnd)
        await editor.window.reviewSeek(to: 1)
        #expect(editor.window.reviewCurrentTime == 1)
        editor.keepWhole.performClick(nil)
        editor.window.reviewUndo()
        #expect(editor.window.reviewTrim == VideoTrim(start: 0.5, end: 1.5, recording: 2))
        try await Task.sleep(for: .milliseconds(1500))
        #expect(editor.window.reviewCurrentTime == 1, "The preview must stay inside the restored trim.")
    }

    private var decimal: String { Locale.current.decimalSeparator ?? "." }

    private func key(_ character: String, keyCode: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: character, charactersIgnoringModifiers: character,
            isARepeat: false, keyCode: keyCode))
    }
}

@MainActor private final class Editor {
    let window: VideoEditorWindow
    let trimStart: NSTextField
    let trimEnd: NSTextField
    let handles: VideoRangeControl
    let keepWhole: NSButton
    private(set) var saved: VideoEdit?
    private let directory: URL

    init(frameCount: Int = 60) async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let source = directory.appendingPathComponent("source.mp4")
        try await Self.writeVideo(to: source, frameCount: frameCount)
        window = VideoEditorWindow(source: source, duration: Double(frameCount) / 30,
                                   sourceSize: CGSize(width: 160, height: 90))
        window.contentView?.layoutSubtreeIfNeeded()
        let views = Self.descendants(window.contentView!)
        let fields = views.compactMap { $0 as? NSTextField }
        trimStart = try #require(fields.first { $0.accessibilityLabel() == "Trim start in seconds" })
        trimEnd = try #require(fields.first { $0.accessibilityLabel() == "Trim end in seconds" })
        handles = try #require(views.compactMap { $0 as? VideoRangeControl }
            .first { $0.accessibilityLabel() == "Kept part of the recording" })
        keepWhole = try #require(views.compactMap { $0 as? NSButton }.first { $0.title == "Keep whole recording" })
        window.onSave = { [weak self] edit in self?.saved = edit }
        await window.reviewSeek(to: 0)
    }

    deinit {
        MainActor.assumeIsolated { window.close() }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Types into the field editor without pressing Return.
    func type(_ text: String, into field: NSTextField) {
        window.makeFirstResponder(field)
        guard let editor = field.currentEditor() as? NSTextView else {
            Issue.record("The time field did not start editing.")
            return
        }
        editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    }

    func commit(_ text: String, into field: NSTextField) {
        type(text, into: field)
        window.makeFirstResponder(window.canvas)
    }

    /// Mouse down at the first time, drags through the rest, then mouse up.
    func drag(_ control: VideoRangeControl, through times: [TimeInterval]) throws {
        for (index, time) in times.enumerated() {
            let track = control.bounds.insetBy(dx: 10, dy: 10)
            let point = control.convert(CGPoint(x: track.minX + track.width * time / control.duration,
                                                y: control.bounds.midY), to: nil)
            let event = try mouse(index == 0 ? .leftMouseDown : .leftMouseDragged, at: point)
            if index == 0 { control.mouseDown(with: event) } else { control.mouseDragged(with: event) }
        }
        control.mouseUp(with: try mouse(.leftMouseUp, at: .zero))
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private static func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }

    private static func writeVideo(to url: URL, frameCount: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90,
        ])
        let attributes = CVPixelBufferCreationAttributes(pixelFormatType: .init(rawValue: kCVPixelFormatType_32BGRA),
                                                        size: .init(width: 160, height: 90))
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: attributes)
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frameCount {
            let pixel = try CVMutablePixelBuffer(attributes)
            let buffer = CVReadOnlyPixelBuffer(pixel)
            try await RecordingExport.appendWhenReady {
                try receiver.appendImmediately(buffer, with: CMTime(value: Int64(frame), timescale: 30))
            }
        }
        receiver.finish()
        writer.endSession(atSourceTime: CMTime(value: Int64(frameCount), timescale: 30))
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }
}
