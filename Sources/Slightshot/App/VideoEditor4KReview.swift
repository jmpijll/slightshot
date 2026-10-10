import AppKit
import AVFoundation
import CryptoKit
import Darwin

/// A short native 4K workload. Product rendering/export code stays untouched,
/// so this instrument can be copied onto the baseline commit for comparison.
enum VideoEditor4KReview {
    static let sourceSize = CGSize(width: 3840, height: 2160)
    static let duration: TimeInterval = 2
    private static let fps: Int32 = 24
    private static let start: TimeInterval = 0.6
    private static let end: TimeInterval = 1.4
    private static let samples: [(String, TimeInterval)] = [("before", 0.25), ("during", 1), ("after", 1.75)]

    static func capture(in window: VideoEditorWindow, source: URL, directory: URL, sourceCommit: String,
                        captureWindow: (NSWindow, URL) async throws -> String) async throws {
        let sourceAsset = AVURLAsset(url: source)
        let track = try await sourceAsset.loadTracks(withMediaType: .video).first
        guard let track, try await track.load(.naturalSize) == sourceSize,
              abs(try await sourceAsset.load(.duration).seconds - duration) < 0.01 else {
            throw RecordingError.failed("The 4K performance fixture requires the generated two-second 3840×2160 input.")
        }
        let sourceHash = SHA256.hash(data: try Data(contentsOf: source)).map { String(format: "%02x", $0) }.joined()
        let sourceMemory = ReviewMemoryProbe.residentBytes()
        await window.reviewSeek(to: 0.25)
        try await Task.sleep(for: .milliseconds(150))
        window.contentView?.layoutSubtreeIfNeeded()
        let gestures = try makeAnnotations(in: window)
        let annotations = try committedAnnotations(in: window)
        var report: [String: Any] = [
            "platform": "macOS", "sourceCommit": sourceCommit,
            "fixtureInstrumentationSHA256": ProcessInfo.processInfo.environment["SLIGHTSHOT_REVIEW_FIXTURE_SHA256"]
                ?? "unspecified",
            "fixture": "Synthetic 3840×2160, 2 second H.264 movie at 24 fps; 48 source frames. "
                + "Native HiDPI UI text: 27/25 point fonts rendered at 2× (54/50 source pixels). "
                + "Name/email and a code marker move inside fixed privacy rectangles. No personal data.",
            "sourceSHA256": sourceHash, "sourceFile": source.lastPathComponent,
            "sourceFrames": 48, "sourceWidth": 3840, "sourceHeight": 2160,
            "annotationRangeSeconds": [start, end], "annotationCount": annotations.count,
            "annotations": annotations.map(annotationMetadata),
            "canvasFitScale": window.canvas.imageRect.width / sourceSize.width,
            "nativeGestureAndDrawSamples": gestures,
            "residentBytesAfterSourceLoading": sourceMemory.map { $0 as Any } ?? "unavailable",
            "memoryMetric": "Mach task resident_size sampled every 50 ms during export; "
                + "an observed peak, not an operating-system lifetime high-water mark.",
            "heartbeatMetric": "A MainActor task samples every 50 ms during export. The maximum observed gap "
                + "includes annotation preparation and the final sample; it measures main-actor scheduling "
                + "responsiveness, not a separate interactive input latency guarantee.",
        ]
        try write(report.merging(["state": "preview captures pending"]) { _, new in new },
                  to: directory.appendingPathComponent("4k-performance-partial.json"))
        var captures: [[String: Any]] = []
        for (name, time) in samples {
            let began = ProcessInfo.processInfo.systemUptime
            await window.reviewSeek(to: time)
            window.canvas.displayIfNeeded()
            let elapsed = (ProcessInfo.processInfo.systemUptime - began) * 1_000
            guard abs(window.reviewCurrentTime - time) < 0.01 else {
                throw RecordingError.failed("4K preview requested \(time)s but displays \(window.reviewCurrentTime)s.")
            }
            try await Task.sleep(for: .milliseconds(150))
            let filename = "mac-4k-\(name).png"
            let method = try await captureWindow(window, directory.appendingPathComponent(filename))
            let captureReport: [String: Any] = ["file": filename, "requestedTimeSeconds": time,
                "verifiedPlayheadSeconds": window.reviewCurrentTime, "source": method,
                "sourceCommit": sourceCommit, "platform": "macOS",
                "seekAndNativeDrawMilliseconds": elapsed]
            captures.append(captureReport)
            try write(captureReport, to: directory.appendingPathComponent("mac-4k-\(name)-source.json"))
        }
        report["captures"] = captures
        var exports: [[String: Any]] = []
        for quality in [RecordingQuality.high, .balanced] {
            report["exports"] = exports
            report["state"] = "Export \(quality.title) starting"
            try write(report, to: directory.appendingPathComponent("4k-performance-partial.json"))
            let destination = directory.appendingPathComponent("edited-4k-\(quality.rawValue).mp4")
            exports.append(try await measureExport(source: source, destination: destination,
                                                  annotations: annotations, quality: quality))
            let frames = try await exportFrames(at: destination, directory: directory, quality: quality)
            exports[exports.count - 1]["frames"] = frames
        }
        report["exports"] = exports
        report["state"] = "Active 4K cancellation starting"
        try write(report, to: directory.appendingPathComponent("4k-performance-partial.json"))
        report["activeCancellation"] = try await measureCancellation(in: window, source: source,
            sourceHash: sourceHash, directory: directory, annotations: annotations)
        report["state"] = "Complete"
        report["measurementScope"] = "Native seek includes frame generation, annotation composition and synchronous "
            + "canvas display. Gesture time includes native mouse events and canvas display. "
            + "Export wall time includes annotation preparation, decoding, effects, resizing and encoding; "
            + "evidence extraction is excluded. Qualities run serially with no source regeneration."
        try write(report, to: directory.appendingPathComponent("4k-performance.json"))
        await window.reviewSeek(to: 1)
    }

    private static func makeAnnotations(in window: VideoEditorWindow) throws -> [[String: Any]] {
        let canvas = window.canvas
        let recipes: [(Tool, [CGPoint])] = [
            (.blur, [CGPoint(x: 1000, y: 760), CGPoint(x: 2050, y: 885)]),
            (.pixelate, [CGPoint(x: 1000, y: 968), CGPoint(x: 2650, y: 1093)]),
            (.arrow, [CGPoint(x: 3200, y: 900), CGPoint(x: 2820, y: 1150)]),
            (.pen, [CGPoint(x: 2460, y: 1490), CGPoint(x: 2530, y: 1540), CGPoint(x: 2630, y: 1480)]),
            (.text, [CGPoint(x: 2740, y: 650)]),
        ]
        var measurements: [[String: Any]] = []
        for (tool, points) in recipes {
            guard let button = descendants(window.contentView!).compactMap({ $0 as? ToolbarButton })
                .first(where: { $0.accessibilityLabel() == tool.title }) else {
                throw RecordingError.failed("The native \(tool.title) toolbar button is unavailable.")
            }
            button.performClick(nil)
            let began = ProcessInfo.processInfo.systemUptime
            try gesture(points, in: canvas)
            if tool == .text {
                guard let entry = descendants(canvas).compactMap({ $0 as? TextEntryView }).first else {
                    throw RecordingError.failed("The native text entry is unavailable.")
                }
                entry.insertText("Inspect detail", replacementRange: NSRange(location: NSNotFound, length: 0))
                canvas.commitTextEntry()
            }
            window.reviewSetRange(start: start, end: end)
            canvas.displayIfNeeded()
            measurements.append(["tool": tool.title,
                "nativeMouseEvents": points.count + 1,
                "nativeGestureAndDrawMilliseconds": (ProcessInfo.processInfo.systemUptime - began) * 1_000])
        }
        window.reviewSelectAnnotation(index: 2)
        return measurements
    }

    private static func committedAnnotations(in window: VideoEditorWindow) throws -> [VideoAnnotation] {
        guard let save = descendants(window.contentView!).compactMap({ $0 as? NSButton })
            .first(where: { $0.title == "Save MP4…" }) else {
            throw RecordingError.failed("The native Save MP4 button is unavailable.")
        }
        let previous = window.onSave
        defer { window.onSave = previous }
        var result: [VideoAnnotation]?
        window.onSave = { result = $0 }
        save.performClick(nil)
        guard let result, result.count == 5 else { throw RecordingError.failed("Five native marks were expected.") }
        return result
    }

    private static func gesture(_ sourcePoints: [CGPoint], in canvas: VideoCanvasView) throws {
        let points = sourcePoints.map { point in
            CGPoint(x: canvas.imageRect.minX + point.x * canvas.imageRect.width / sourceSize.width,
                    y: canvas.imageRect.minY + point.y * canvas.imageRect.height / sourceSize.height)
        }
        guard let first = points.first, let last = points.last else { return }
        canvas.mouseDown(with: try event(.leftMouseDown, at: first, in: canvas))
        for point in points.dropFirst() {
            canvas.mouseDragged(with: try event(.leftMouseDragged, at: point, in: canvas))
        }
        canvas.mouseUp(with: try event(.leftMouseUp, at: last, in: canvas))
    }

    private static func event(_ type: NSEvent.EventType, at point: CGPoint, in view: NSView) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
            throw RecordingError.failed("The native review mouse event could not be created.")
        }
        return event
    }

    private static func measureExport(source: URL, destination: URL, annotations: [VideoAnnotation],
                                      quality: RecordingQuality) async throws -> [String: Any] {
        let memory = ReviewMemoryProbe()
        memory.sample()
        let initial = memory.peak
        let monitor = Task { @MainActor in
            while !Task.isCancelled {
                memory.sample()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { monitor.cancel() }
        let began = ProcessInfo.processInfo.systemUptime
        try await RecordingExport.save(source: source, to: destination, quality: quality, annotations: annotations)
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        monitor.cancel()
        await monitor.value
        memory.sample()
        let asset = AVURLAsset(url: destination)
        guard try await asset.load(.isPlayable),
              abs(try await asset.load(.duration).seconds - duration) < 0.1 else {
            throw RecordingError.failed("The measured 4K export is not a playable two-second movie.")
        }
        let dimensions = quality.dimensions(for: sourceSize)
        return ["quality": quality.title, "file": destination.lastPathComponent,
                "outputWidth": dimensions.width, "outputHeight": dimensions.height,
                "outputFPS": quality.framesPerSecond,
                "expectedOutputFrames": Int(duration * Double(quality.framesPerSecond)),
                "wallSeconds": elapsed, "secondsPerSourceSecond": elapsed / duration,
                "residentBytesBeforeExport": initial, "observedResidentBytesPeak": memory.peak,
                "residentSamples": memory.count, "mainActorHeartbeatSamples": memory.heartbeatCount,
                "mainActorHeartbeatMaximumGapMilliseconds": memory.maximumHeartbeatGap * 1_000,
                "fileBytes": try Data(contentsOf: destination).count]
    }

    private static func measureCancellation(in window: VideoEditorWindow, source: URL, sourceHash: String,
                                            directory: URL, annotations: [VideoAnnotation]) async throws
        -> [String: Any] {
        let cancellationDirectory = directory.appendingPathComponent("active-4k-cancellation", isDirectory: true)
        try FileManager.default.createDirectory(at: cancellationDirectory, withIntermediateDirectories: true)
        let destination = cancellationDirectory.appendingPathComponent("existing.mp4")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: directory.appendingPathComponent("edited-4k-2.mp4"), to: destination)
        let previousHash = try fileHash(destination)
        let previousMarks = try annotationSnapshot(annotations)
        let task = Task {
            try await RecordingExport.save(source: source, to: destination, quality: .high, annotations: annotations)
        }
        let progress = RecordingExportPanel { task.cancel() }
        progress.makeKeyAndOrderFront(nil)
        defer { progress.close(); task.cancel() }
        guard let cancel = descendants(progress.contentView!).compactMap({ $0 as? NSButton })
            .first(where: { $0.title == "Cancel" }) else {
            throw RecordingError.failed("The native export Cancel button is unavailable.")
        }
        let began = ProcessInfo.processInfo.systemUptime
        var stagedBytes = 0
        while ProcessInfo.processInfo.systemUptime - began < 10 {
            let staging = try FileManager.default.contentsOfDirectory(at: cancellationDirectory,
                includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".slightshot-") }
            for staged in staging {
                let output = staged.appendingPathComponent("recording.mp4")
                if let size = try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    stagedBytes = max(stagedBytes, size)
                }
            }
            if stagedBytes > 4096 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard stagedBytes > 4096 else {
            throw RecordingError.failed("The active cancellation fixture did not observe encoded 4K output bytes.")
        }
        let cancellationBegan = ProcessInfo.processInfo.systemUptime
        cancel.performClick(nil)
        do {
            try await task.value
            throw RecordingError.failed("The active 4K export completed before cancellation took effect.")
        } catch is CancellationError {
            // The production Cancel route must return the cancellation outcome.
        }
        let cancellationSeconds = ProcessInfo.processInfo.systemUptime - cancellationBegan
        progress.close()
        let sourcePreserved = try fileHash(source) == sourceHash
        let destinationPreserved = try fileHash(destination) == previousHash
        let editsPreserved = try annotationSnapshot(committedAnnotations(in: window)) == previousMarks
        let remaining = try FileManager.default.contentsOfDirectory(atPath: cancellationDirectory.path).sorted()
        guard sourcePreserved, destinationPreserved, editsPreserved, remaining == ["existing.mp4"] else {
            throw RecordingError.failed("Active 4K cancellation failed preservation or staging cleanup validation.")
        }
        return ["quality": RecordingQuality.high.title, "action": "Native RecordingExportPanel Cancel button click",
                "stagedOutputBytesObservedBeforeCancel": stagedBytes, "cancellationWallSeconds": cancellationSeconds,
                "cancelRequestedTimeSecondsSinceExportStart": cancellationBegan - began,
                "sourceSHA256BeforeAndAfter": sourceHash, "existingDestinationSHA256BeforeAndAfter": previousHash,
                "sourcePreserved": sourcePreserved, "existingDestinationPreserved": destinationPreserved,
                "editsPreserved": editsPreserved, "annotationCountAfterCancel": annotations.count,
                "stagingCleanedUp": true, "outcome": "CancellationError"]
    }

    private static func fileHash(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private static func annotationSnapshot(_ annotations: [VideoAnnotation]) throws -> Data {
        let metadata = annotations.map { annotationMetadata($0).merging(["id": $0.id.uuidString]) { _, new in new } }
        return try JSONSerialization.data(withJSONObject: metadata, options: .sortedKeys)
    }

    private static func exportFrames(at url: URL, directory: URL, quality: RecordingQuality) async throws -> [String] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var files: [String] = []
        for (name, time) in samples {
            let frame = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
            let filename = "export-4k-\(quality.rawValue)-\(name).png"
            guard let png = Renderer.encode(frame.image, as: .png, quality: 1) else {
                throw RecordingError.failed("The 4K export evidence frame could not be encoded.")
            }
            try png.write(to: directory.appendingPathComponent(filename), options: .atomic)
            files.append(filename)
        }
        return files
    }

    private static func annotationMetadata(_ timed: VideoAnnotation) -> [String: Any] {
        let value = timed.annotation
        var metadata: [String: Any] = ["shape": String(describing: value.shape),
            "startSeconds": timed.start, "endSeconds": timed.end,
            "lineWidthSourcePixels": value.lineWidth, "fontSizeSourcePixels": value.fontSize, "alpha": value.alpha]
        // Baseline lacks an effect-scale property; discover it without coupling
        // this fixture to the fix under measurement.
        for child in Mirror(reflecting: value).children {
            guard let label = child.label, label.localizedCaseInsensitiveContains("scale") else { continue }
            if let scale = child.value as? CGFloat { metadata[label] = scale }
        }
        return metadata
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    static func makeSource(at url: URL) async throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 3840, AVVideoHeightKey: 2160,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 48_000_000],
        ])
        let attributes = CVPixelBufferCreationAttributes(
            pixelFormatType: .init(rawValue: kCVPixelFormatType_32BGRA), size: .init(width: 3840, height: 2160))
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: attributes)
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        do {
            for index in 0..<48 {
                try Task.checkCancellation()
                let pixel = try CVMutablePixelBuffer(attributes)
                try pixel.withUnsafeBuffer { try drawFrame(index: index, into: $0) }
                let frame = CVReadOnlyPixelBuffer(pixel)
                let timestamp = CMTime(value: Int64(index), timescale: fps)
                while try !receiver.appendImmediately(frame, with: timestamp) {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(1))
                }
            }
            receiver.finish()
            writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: fps))
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw writer.error ?? RecordingError.failed("4K fixture encoding failed.")
            }
        } catch {
            if writer.status == .writing { writer.cancelWriting() }
            throw error
        }
    }

    private static func drawFrame(index: Int, into buffer: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 3840, height: 2160,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue) else {
            throw RecordingError.failed("The 4K fixture drawing context is unavailable.")
        }
        context.translateBy(x: 0, y: 2160)
        context.scaleBy(x: 2, y: -2)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        NSColor(srgbRed: 0.06, green: 0.09, blue: 0.14, alpha: 1).setFill()
        CGRect(x: 0, y: 0, width: 1920, height: 1080).fill()
        text("4K DEMO WORKSPACE", at: CGPoint(x: 100, y: 72), size: 36, color: .white)
        text("Native HiDPI text · synthetic inputs · fixed masks over moving details", at: CGPoint(x: 100, y: 130),
             size: 21, color: .lightGray)
        NSColor(srgbRed: 0.11, green: 0.15, blue: 0.22, alpha: 1).setFill()
        for box in [CGRect(x: 80, y: 250, width: 300, height: 650), CGRect(x: 420, y: 250, width: 1420, height: 650)] {
            NSBezierPath(roundedRect: box, xRadius: 16, yRadius: 16).fill()
        }
        for (row, name) in ["Overview", "Demo account", "Activity", "Review settings"].enumerated() {
            text(name, at: CGPoint(x: 112, y: 300 + row * 75), size: 23, color: .white)
        }
        text("ACCOUNT PROFILE", at: CGPoint(x: 520, y: 300), size: 22, color: .lightGray)
        let drift = sin(Double(index) / 48 * .pi * 2) * 8
        text("Demo Reviewer", at: CGPoint(x: 520 + drift, y: 398), size: 27, color: .white)
        text("ID: DEMO-042", at: CGPoint(x: 890 - drift, y: 404), size: 20, color: .lightGray)
        text("demo@example.invalid", at: CGPoint(x: 520 - drift, y: 505), size: 25, color: .white)
        text("Code \(String(format: "%02d", index))", at: CGPoint(x: 1170 + drift, y: 510), size: 19, color: .white)
        NSColor(srgbRed: 0.19, green: 0.7, blue: 0.56, alpha: 1).setFill()
        NSBezierPath(ovalIn: CGRect(x: 1400, y: 565, width: 20, height: 20)).fill()
        text("Ready for review", at: CGPoint(x: 1430, y: 560), size: 24, color: .white)
        text("Moving detail verifies that effects follow current frames", at: CGPoint(x: 520, y: 655),
             size: 21, color: .lightGray)
        for row in 0..<5 {
            for column in 0..<24 {
                let hue = CGFloat((row * 24 + column + index) % 48) / 48
                NSColor(hue: hue, saturation: 0.5, brightness: 0.7, alpha: 1).setFill()
                CGRect(x: 520 + column * 22, y: 710 + row * 16, width: 18, height: 12).fill()
            }
        }
        NSColor.white.setFill()
        NSBezierPath(ovalIn: CGRect(x: 100 + CGFloat(index) / 47 * 1530, y: 982, width: 14, height: 14)).fill()
        text(String(format: "%.2f s", Double(index) / Double(fps)), at: CGPoint(x: 1690, y: 975),
             size: 24, color: .white)
    }

    private static func text(_ value: String, at origin: CGPoint, size: CGFloat, color: NSColor) {
        (value as NSString).draw(at: origin, withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: color,
        ])
    }

    private static func write(_ report: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: url, options: .atomic)
    }
}

private final class ReviewMemoryProbe {
    private(set) var peak: UInt64 = 0
    private(set) var count = 0
    private(set) var heartbeatCount = 0
    private(set) var maximumHeartbeatGap: TimeInterval = 0
    private var previousHeartbeat: TimeInterval?

    func sample() {
        let now = ProcessInfo.processInfo.systemUptime
        if let previousHeartbeat { maximumHeartbeatGap = max(maximumHeartbeatGap, now - previousHeartbeat) }
        previousHeartbeat = now
        heartbeatCount += 1
        guard let value = Self.residentBytes() else { return }
        peak = max(peak, value)
        count += 1
    }

    static func residentBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.resident_size : nil
    }
}
