import AppKit
import AVFoundation

/// Trim evidence on the synthetic eight-second fixture. Mouse events drag the
/// native trim handles, typed values go through the trim fields' actions,
/// ⌘Z/⌘⇧Z go through the window's key equivalents, and Play and Save MP4 are
/// clicked. Exports run the production save at every quality.
@MainActor enum VideoEditorTrimReview {
    private static let keptStart: TimeInterval = 1.5
    private static let keptEnd: TimeInterval = 6
    private static let arrow = CGRect(x: 525, y: 175, width: 240, height: 135)
    private static let caption = CGRect(x: 640, y: 150, width: 200, height: 40)
    private static let blur = CGRect(x: 70, y: 196, width: 335, height: 48)

    private struct Controls {
        let handles: VideoRangeControl
        let startField: NSTextField
        let endField: NSTextField
        let play: NSButton
        let save: NSButton
    }

    static func capture(in window: VideoEditorWindow, source: URL, directory: URL, sourceCommit: String,
                        captureWindow: (NSWindow, URL) async throws -> String) async throws {
        let red = NSColor.systemRed
        let marks = [
            VideoAnnotation(annotation: Annotation(shape: .arrow(from: CGPoint(x: 735, y: 210),
                to: CGPoint(x: 565, y: 270)), color: red, lineWidth: 6), start: 2, end: 5),
            VideoAnnotation(annotation: Annotation(shape: .text("Trimmed out", origin: CGPoint(x: 650, y: 155)),
                color: red, lineWidth: 5, fontSize: 28), start: 0, end: 1),
            VideoAnnotation(annotation: Annotation(shape: .blur(blur), color: red, lineWidth: 5), start: 5, end: 7.5),
        ]
        for mark in marks { window.reviewAddAnnotation(mark) }
        window.reviewSelectAnnotation(index: 2)
        await window.reviewSeek(to: 0)
        window.contentView?.layoutSubtreeIfNeeded()
        let controls = try findControls(in: window)
        let movie = directory.appendingPathComponent("mac-trim-demo-raw.mp4")
        let recorder = NativeWindowDemoRecorder(destination: movie)
        try await recorder.start(window: window)
        let steps: [[String: Any]]
        let playback: [String: Any]
        do {
            steps = try await editTrim(in: window, controls: controls)
            playback = try await play(in: window, controls: controls)
            await window.reviewSeek(to: 3.5)
            try await Task.sleep(for: .milliseconds(900))
            _ = try await recorder.stop()
        } catch {
            _ = try? await recorder.stop()
            throw error
        }
        let screenshot = try await captureWindow(window, directory.appendingPathComponent("mac-trim-editor.png"))
        let edit = try savedEdit(in: window, save: controls.save)
        let exports = try await export(edit, source: source, directory: directory)
        let frames = try await frameChecks(source: source, output: directory.appendingPathComponent("trimmed-high.mp4"),
                                           directory: directory)
        let report: [String: Any] = [
            "platform": "macOS", "sourceCommit": sourceCommit,
            "fixture": "Synthetic 960×540, 8 second movie at 24 fps with a burned-in source time stamp. "
                + "Demo Reviewer and demo@example.invalid are fixture inputs. No desktop pixels or personal data.",
            "interaction": "Automated: synthetic mouse drags on the native trim handles, typed trim fields, "
                + "⌘Z/⌘⇧Z key equivalents, Play and Save MP4 button clicks. Exports use RecordingExport.save "
                + "with the edit returned by Save MP4.",
            "annotationsSourceSeconds": ["arrow": [2, 5], "caption": [0, 1], "blur": [5, 7.5]],
            "trimSteps": steps, "playback": playback,
            "savedTrimSeconds": [edit.trim.start, edit.trim.end],
            "editorScreenshot": ["file": "mac-trim-editor.png", "source": screenshot, "playheadSeconds": 3.5],
            "demoVideo": "mac-trim-demo.mp4 (ScreenCaptureKit recording of the editor window only)",
            "exports": exports, "frames": frames,
        ]
        let passed = validate(edit: edit, playback: playback, exports: exports, frames: frames)
        try write(report.merging(["result": passed ? "Passed" : "Failed"]) { $1 },
                  to: directory.appendingPathComponent("mac-trim-validation.json"))
        guard passed else { throw RecordingError.failed("Trim review validation failed.") }
    }

    private static func findControls(in window: NSWindow) throws -> Controls {
        let views = descendants(window.contentView!)
        let buttons = views.compactMap { $0 as? NSButton }
        let fields = views.compactMap { $0 as? NSTextField }
        guard let handles = views.compactMap({ $0 as? VideoRangeControl })
                .first(where: { $0.accessibilityLabel() == "Kept part of the recording" }),
              let startField = fields.first(where: { $0.accessibilityLabel() == "Trim start in seconds" }),
              let endField = fields.first(where: { $0.accessibilityLabel() == "Trim end in seconds" }),
              let play = buttons.first(where: { $0.title == "Play" }),
              let save = buttons.first(where: { $0.title == "Save MP4…" }) else {
            throw RecordingError.failed("The native trim controls are unavailable.")
        }
        return Controls(handles: handles, startField: startField, endField: endField, play: play, save: save)
    }

    private static func editTrim(in window: VideoEditorWindow, controls: Controls) async throws -> [[String: Any]] {
        var steps: [[String: Any]] = []
        func record(_ step: String) {
            steps.append(["step": step, "trimSeconds": [window.reviewTrim.start, window.reviewTrim.end],
                          "playheadSeconds": window.reviewCurrentTime])
        }
        try await Task.sleep(for: .milliseconds(800))
        try await drag(controls.handles, in: window, from: 0, to: keptStart)
        record("Dragged the start handle toward 1.5 s")
        try await drag(controls.handles, in: window, from: 8, to: keptEnd)
        record("Dragged the end handle toward 6 s")
        for (field, text) in [(controls.startField, "1.50"), (controls.endField, "6.00")] {
            field.stringValue = text
            field.sendAction(field.action, to: field.target)
            try await Task.sleep(for: .milliseconds(500))
        }
        record("Typed 1.50 and 6.00 into the trim fields")
        window.makeFirstResponder(window.canvas)
        for (shift, step) in [(false, "⌘Z restores the dragged end"), (true, "⌘⇧Z restores the typed end")] {
            _ = window.performKeyEquivalent(with: try key("z", shift: shift, in: window))
            try await Task.sleep(for: .milliseconds(700))
            record(step)
        }
        return steps
    }

    private static func play(in window: VideoEditorWindow, controls: Controls) async throws -> [String: Any] {
        controls.play.performClick(nil)
        var times: [TimeInterval] = []
        for _ in 0..<200 {
            try await Task.sleep(for: .milliseconds(50))
            times.append(window.reviewCurrentTime)
            if controls.play.title == "Play", times.count > 4 { break }
        }
        try await Task.sleep(for: .milliseconds(600))
        return ["pressedPlayAtSeconds": window.reviewTrim.end, "firstSampleSeconds": times.first ?? -1,
                "minimumSeconds": times.min() ?? -1, "maximumSeconds": times.max() ?? -1,
                "stoppedAtSeconds": window.reviewCurrentTime, "samples": times.count]
    }

    private static func drag(_ control: VideoRangeControl, in window: NSWindow,
                             from: TimeInterval, to: TimeInterval) async throws {
        func point(_ time: TimeInterval) -> CGPoint {
            let track = control.bounds.insetBy(dx: 10, dy: 10)
            let x = track.minX + track.width * time / control.duration
            return control.convert(CGPoint(x: x, y: control.bounds.midY), to: nil)
        }
        let steps = 24
        for step in 0...steps {
            let time = from + (to - from) * Double(step) / Double(steps)
            window.sendEvent(try mouse(step == 0 ? .leftMouseDown : .leftMouseDragged, at: point(time), in: window))
            try await Task.sleep(for: .milliseconds(35))
        }
        window.sendEvent(try mouse(.leftMouseUp, at: point(to), in: window))
        try await Task.sleep(for: .milliseconds(600))
    }

    private static func mouse(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else {
            throw RecordingError.failed("A trim drag event could not be created.")
        }
        return event
    }

    private static func key(_ character: String, shift: Bool, in window: NSWindow) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: shift ? [.command, .shift] : .command, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: character,
            charactersIgnoringModifiers: character, isARepeat: false, keyCode: 6) else {
            throw RecordingError.failed("An Undo key event could not be created.")
        }
        return event
    }

    private static func savedEdit(in window: VideoEditorWindow, save: NSButton) throws -> VideoEdit {
        let previous = window.onSave
        defer { window.onSave = previous }
        var result: VideoEdit?
        window.onSave = { result = $0 }
        save.performClick(nil)
        guard let result else { throw RecordingError.failed("Save MP4 did not return the edit.") }
        return result
    }

    private static func export(_ edit: VideoEdit, source: URL, directory: URL) async throws -> [[String: Any]] {
        var exports: [[String: Any]] = []
        for quality in RecordingQuality.allCases {
            let name = ["compact", "balanced", "high"][quality.rawValue]
            let output = directory.appendingPathComponent("trimmed-\(name).mp4")
            try await RecordingExport.save(source: source, to: output, quality: quality,
                                           annotations: edit.annotations, trim: edit.trim)
            let asset = AVURLAsset(url: output)
            let track = try await asset.loadTracks(withMediaType: .video).first
            let frameCount = try await countFrames(asset: asset, track: track)
            let fps = min(Double(quality.framesPerSecond), 24)
            exports.append(["quality": quality.title, "file": output.lastPathComponent,
                            "durationSeconds": try await asset.load(.duration).seconds,
                            "trimSeconds": edit.trim.duration, "frameCount": frameCount,
                            "expectedFrameCount": Int((edit.trim.duration * fps).rounded()),
                            "framesPerSecond": fps, "bytes": try Data(contentsOf: output).count])
        }
        return exports
    }

    private static func countFrames(asset: AVAsset, track: AVAssetTrack?) async throws -> Int {
        guard let track else { return 0 }
        let reader = try AVAssetReader(asset: asset)
        let provider = reader.outputProvider(for: AVAssetReaderTrackOutput(track: track, outputSettings: nil))
        try reader.start()
        var count = 0
        while let sample = try await provider.next() {
            if sample.contentType == .dataBuffer { count += 1 }
        }
        return count
    }

    /// Export time t shows source time t + 1.5 s.
    private static func frameChecks(source: URL, output: URL, directory: URL) async throws -> [String: Any] {
        let first = try await image(in: output, at: 0)
        if let png = Renderer.encode(first, as: .png, quality: 1) {
            try png.write(to: directory.appendingPathComponent("mac-trim-export-first-frame.png"), options: .atomic)
        }
        func frame(_ url: URL, _ time: TimeInterval) async throws -> [UInt8] {
            try ReviewPixels.rgba(try await image(in: url, at: time))
        }
        let exportStart = try ReviewPixels.rgba(first)
        let whole = CGRect(x: 0, y: 0, width: 960, height: 540)
        let early = try await frame(output, 0.25)
        let during = try await frame(output, 2)
        let blurOff = try await frame(output, 3)
        let blurOn = try await frame(output, 4.25)
        return [
            "firstFrameDifferenceFromSource1_5s": ReviewPixels.difference(exportStart,
                try await frame(source, keptStart), in: whole),
            "firstFrameDifferenceFromSource0s": ReviewPixels.difference(exportStart,
                try await frame(source, 0), in: whole),
            "arrowRedFractionAtExport0_25s": ReviewPixels.redFraction(early, in: arrow),
            "arrowRedFractionAtExport2s": ReviewPixels.redFraction(during, in: arrow),
            "captionRedFractionAtExport0_25s": ReviewPixels.redFraction(early, in: caption),
            "blurDifferenceFromSourceAtExport3s": ReviewPixels.difference(blurOff,
                try await frame(source, 4.5), in: blur),
            "blurDifferenceFromSourceAtExport4_25s": ReviewPixels.difference(blurOn,
                try await frame(source, 5.75), in: blur),
        ]
    }

    private static func image(in url: URL, at time: TimeInterval) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
    }

    private static func validate(edit: VideoEdit, playback: [String: Any], exports: [[String: Any]],
                                 frames: [String: Any]) -> Bool {
        func number(_ values: [String: Any], _ key: String) -> Double { values[key] as? Double ?? .nan }
        let trimmed = edit.trim == VideoTrim(start: keptStart, end: keptEnd, recording: 8)
        let played = number(playback, "minimumSeconds") >= keptStart - 0.001
            && number(playback, "maximumSeconds") <= keptEnd + 0.001
            && number(playback, "maximumSeconds") > keptEnd - 0.2
        let exported = exports.count == 3 && exports.allSatisfy { value in
            abs(number(value, "durationSeconds") - edit.trim.duration) <= 1 / number(value, "framesPerSecond")
                && abs((value["frameCount"] as? Int ?? 0) - (value["expectedFrameCount"] as? Int ?? -9)) <= 1
        }
        let shifted = number(frames, "firstFrameDifferenceFromSource1_5s") * 4
                < number(frames, "firstFrameDifferenceFromSource0s")
            && number(frames, "arrowRedFractionAtExport0_25s") < 0.001
            && number(frames, "arrowRedFractionAtExport2s") > 0.003
            && number(frames, "captionRedFractionAtExport0_25s") < 0.001
            && number(frames, "blurDifferenceFromSourceAtExport4_25s")
                > number(frames, "blurDifferenceFromSourceAtExport3s") + 2.5
        return trimmed && played && exported && shifted
    }

    private static func write(_ value: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}

private enum ReviewPixels {
    static func rgba(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let succeeded = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard succeeded, image.width == 960 else { throw RecordingError.failed("Review frame pixels are unavailable.") }
        return pixels
    }

    static func redFraction(_ pixels: [UInt8], in rect: CGRect) -> Double {
        var red = 0
        var total = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let offset = (y * 960 + x) * 4
                if Int(pixels[offset]) > Int(pixels[offset + 1]) + 45,
                   Int(pixels[offset]) > Int(pixels[offset + 2]) + 45 { red += 1 }
                total += 1
            }
        }
        return Double(red) / Double(total)
    }

    static func difference(_ first: [UInt8], _ second: [UInt8], in rect: CGRect) -> Double {
        var sum = 0
        var count = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let offset = (y * 960 + x) * 4
                for channel in 0..<3 {
                    sum += abs(Int(first[offset + channel]) - Int(second[offset + channel]))
                    count += 1
                }
            }
        }
        return Double(sum) / Double(count)
    }
}
