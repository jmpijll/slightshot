import AppKit
import AVFoundation
import ScreenCaptureKit

/// A bounded native review fixture. Its movie contains synthetic account data
/// only; annotation, timing, preview and export use the production editor.
enum VideoEditorReview {
    static func run() {
        let app = NSApplication.shared
        let arguments = CommandLine.arguments
        let flag = arguments.firstIndex(of: "--video-editor-review")!
        let directory = arguments.indices.contains(flag + 1)
            ? URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("build/video-editor-review", isDirectory: true)
        let review = VideoEditorReviewDelegate(
            directory: directory, automatic: arguments.contains("--video-editor-evidence"))
        app.delegate = review
        app.setActivationPolicy(.regular)
        withExtendedLifetime(review) { app.run() }
    }
}

private final class VideoEditorReviewDelegate: NSObject, NSApplicationDelegate {
    private let directory: URL
    private let automatic: Bool
    private var editor: VideoEditorWindow?
    private var reviewTask: Task<Void, Never>?
    private var expiry: Timer?
    private let sourceSize = CGSize(width: 960, height: 540)
    private let duration: TimeInterval = 8

    init(directory: URL, automatic: Bool) {
        self.directory = directory
        self.automatic = automatic
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        reviewTask = Task { [self] in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for name in ["review-failure.json", "export-validation-failure.json"] {
                    let previousFailure = directory.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: previousFailure.path) {
                        try FileManager.default.removeItem(at: previousFailure)
                    }
                }
                let source = directory.appendingPathComponent("fixture-source.mp4")
                try await makeSource(at: source)
                let window = VideoEditorWindow(source: source, duration: duration, sourceSize: sourceSize)
                window.title = "Slightshot video editor · synthetic review fixture"
                window.appearance = NSAppearance(named: .darkAqua)
                window.backgroundColor = .windowBackgroundColor
                window.contentView?.appearance = window.appearance
                window.onDiscard = { NSApp.terminate(nil) }
                window.onSave = { [weak self] annotations in
                    self?.saveReview(source: source, annotations: annotations)
                }
                editor = window
                window.center()
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                if automatic { try await captureEvidence(in: window, source: source) }
            } catch {
                writeFailure(error)
                Log.app.error("Video editor review failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        let timer = Timer(timeInterval: 300, repeats: false) { _ in
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        expiry = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func saveReview(source: URL, annotations: [VideoAnnotation]) {
        Task {
            do {
                try await RecordingExport.save(source: source,
                    to: directory.appendingPathComponent("edited-video.mp4"),
                    quality: .high, annotations: annotations)
                editor?.title = "Slightshot video editor · exported edited-video.mp4"
            } catch { writeFailure(error) }
        }
    }

    private func captureEvidence(in window: VideoEditorWindow, source: URL) async throws {
        let red = NSColor.systemRed
        let values = [
            Annotation(shape: .blur(CGRect(x: 70, y: 196, width: 335, height: 48)),
                       color: red, lineWidth: 5),
            Annotation(shape: .pixelate(CGRect(x: 70, y: 248, width: 410, height: 48)),
                       color: red, lineWidth: 5),
            Annotation(shape: .arrow(from: CGPoint(x: 735, y: 210), to: CGPoint(x: 565, y: 270)),
                       color: red, lineWidth: 6),
            Annotation(shape: .text("Look here", origin: CGPoint(x: 650, y: 155)),
                       color: red, lineWidth: 5, fontSize: 28),
            Annotation(shape: .stroke(points: [CGPoint(x: 528, y: 365), CGPoint(x: 568, y: 390),
                                                CGPoint(x: 610, y: 345), CGPoint(x: 645, y: 365)]),
                       color: red, lineWidth: 5),
        ]
        for annotation in values {
            window.reviewAddAnnotation(VideoAnnotation(annotation: annotation, start: 2, end: 5))
        }
        window.reviewSelectAnnotation(index: 2)
        // Exercise the same range update and history routes used by the controls.
        window.reviewSetRange(start: 1, end: 6)
        window.reviewUndo()
        window.reviewRedo()
        window.reviewSetRange(start: 2, end: 5)

        var captures: [[String: Any]] = []
        for (name, time) in [("mac-before", 1.0), ("mac-during", 3.5), ("mac-after", 6.5)] {
            try Task.checkCancellation()
            await window.reviewSeek(to: time)
            try await Task.sleep(for: .milliseconds(250))
            let currentTime = window.reviewCurrentTime
            guard abs(currentTime - time) < 0.01 else {
                throw RecordingError.failed("Review requested \(time)s but the editor displays \(currentTime)s.")
            }
            let captureSource = try await capture(window: window,
                to: directory.appendingPathComponent(name + ".png"))
            let captureReport: [String: Any] = ["file": name + ".png", "timeSeconds": time,
                "verifiedPlayheadSeconds": currentTime,
                "source": captureSource, "window": "VideoEditorWindow", "platform": "macOS",
                "sourceCommit": sourceCommit,
                "interaction": "Automated annotation commit, range editing, undo/redo and seek."]
            captures.append(captureReport)
            try writeJSON(captureReport, name: name + "-source.json")
        }
        let output = directory.appendingPathComponent("edited-video.mp4")
        let timed = values.map { VideoAnnotation(annotation: $0, start: 2, end: 5) }
        try await RecordingExport.save(source: source, to: output, quality: .high, annotations: timed)
        let validation = try await validateExport(source: source, output: output)
        let report: [String: Any] = [
            "platform": "macOS",
            "sourceCommit": sourceCommit,
            "fixture": "Synthetic 960×540, 8 second movie at 24 fps; Demo Reviewer and demo@example.invalid "
                + "are fixture inputs. No desktop pixels or personal data.",
            "interaction": "Automated production annotation commit, range update, undo/redo, seek and export. "
                + "Native editor window screenshots.",
            "effectRangeSeconds": [2, 5],
            "captures": captures,
            "export": "edited-video.mp4",
            "validation": validation,
        ]
        try writeJSON(report, name: "mac-evidence-source.json")
        await window.reviewSeek(to: 3.5)
    }

    private var sourceCommit: String {
        ProcessInfo.processInfo.environment["SLIGHTSHOT_REVIEW_SOURCE_COMMIT"] ?? "unspecified"
    }

    private func capture(window: NSWindow, to destination: URL) async throws -> String {
        let bitmap: NSBitmapImageRep
        let captureSource: String
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let sharedWindow = content.windows.first(where: { $0.windowID == UInt32(window.windowNumber) }) else {
                throw RecordingError.failed("The review window is unavailable for capture.")
            }
            let configuration = SCStreamConfiguration()
            let scale = window.screen?.backingScaleFactor ?? 1
            configuration.width = Int(window.frame.width * scale)
            configuration.height = Int(window.frame.height * scale)
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            configuration.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: sharedWindow),
                configuration: configuration)
            bitmap = NSBitmapImageRep(cgImage: image)
            captureSource = "ScreenCaptureKit screenshot of the running native VideoEditorWindow; "
                + "synthetic source movie."
        } catch {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rendered = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw error }
            view.displayIfNeeded()
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                if let graphics = NSGraphicsContext(bitmapImageRep: rendered) {
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = graphics
                    NSColor.windowBackgroundColor.setFill()
                    view.bounds.fill()
                    NSGraphicsContext.restoreGraphicsState()
                }
                view.cacheDisplay(in: view.bounds, to: rendered)
            }
            bitmap = rendered
            captureSource = "Native AppKit rendering of the running VideoEditorWindow frame and contents; "
                + "ScreenCaptureKit unavailable: "
                + error.localizedDescription
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw RecordingError.failed("The review screenshot could not be encoded.")
        }
        try png.write(to: destination, options: .atomic)
        return captureSource
    }

    private func validateExport(source: URL, output: URL) async throws -> [String: Any] {
        let control = directory.appendingPathComponent("control-video.mp4")
        // A valid transparent text layer selects the same annotated BGRA export
        // path without changing a pixel. It isolates effects from codec/color drift.
        let transparent = Annotation(shape: .text("", origin: .zero), color: .clear, lineWidth: 1)
        try await RecordingExport.save(source: source, to: control, quality: .high,
            annotations: [VideoAnnotation(annotation: transparent, start: 0, end: duration)])
        let sourceGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        let outputGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        let controlGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: control))
        for generator in [sourceGenerator, outputGenerator, controlGenerator] {
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
        }
        var frames: [[String: Any]] = []
        for (name, time) in [("before", 1.0), ("during", 3.5), ("after", 6.5)] {
            let position = CMTime(seconds: time, preferredTimescale: 600)
            let sourceFrame = try await sourceGenerator.image(at: position).image
            let outputFrame = try await outputGenerator.image(at: position).image
            let controlFrame = try await controlGenerator.image(at: position).image
            guard let png = Renderer.encode(outputFrame, as: .png, quality: 1) else {
                throw RecordingError.failed("The exported review frame could not be encoded.")
            }
            try png.write(to: directory.appendingPathComponent("export-\(name).png"), options: .atomic)
            let sourcePixels = try rgba(sourceFrame)
            let outputPixels = try rgba(outputFrame)
            let controlPixels = try rgba(controlFrame)
            let arrow = CGRect(x: 525, y: 175, width: 240, height: 135)
            let redFraction = fractionOfRedPixels(outputPixels, in: arrow, width: outputFrame.width)
            let blurDifference = difference(controlPixels, outputPixels,
                in: CGRect(x: 70, y: 196, width: 335, height: 48), width: outputFrame.width)
            let pixelateDifference = difference(controlPixels, outputPixels,
                in: CGRect(x: 70, y: 248, width: 410, height: 48), width: outputFrame.width)
            let baselineBlurDifference = difference(sourcePixels, controlPixels,
                in: CGRect(x: 70, y: 196, width: 335, height: 48), width: outputFrame.width)
            let baselinePixelateDifference = difference(sourcePixels, controlPixels,
                in: CGRect(x: 70, y: 248, width: 410, height: 48), width: outputFrame.width)
            frames.append(["timeSeconds": time, "file": "export-\(name).png",
                           "arrowRedPixelFraction": redFraction,
                           "blurRegionMeanRGBDifference": blurDifference,
                           "pixelateRegionMeanRGBDifference": pixelateDifference,
                           "sourceToControlBlurRegionMeanRGBDifference": baselineBlurDifference,
                           "sourceToControlPixelateRegionMeanRGBDifference": baselinePixelateDifference])
        }
        let outputAsset = AVURLAsset(url: output)
        let actualDuration = try await outputAsset.load(.duration).seconds
        let before = frames[0]["arrowRedPixelFraction"] as? Double ?? 1
        let during = frames[1]["arrowRedPixelFraction"] as? Double ?? 0
        let after = frames[2]["arrowRedPixelFraction"] as? Double ?? 1
        let rasterTimingPassed = ["blurRegionMeanRGBDifference", "pixelateRegionMeanRGBDifference"].allSatisfy { key in
            let beforeDifference = frames[0][key] as? Double ?? .infinity
            let duringDifference = frames[1][key] as? Double ?? 0
            let afterDifference = frames[2][key] as? Double ?? .infinity
            return beforeDifference < 1 && afterDifference < 1
                && duringDifference > max(beforeDifference, afterDifference) + 2.5
        }
        guard abs(actualDuration - duration) < 0.1, before < 0.001, during > 0.003, after < 0.001,
              rasterTimingPassed else {
            try writeJSON(["durationSeconds": actualDuration, "frames": frames], name: "export-validation-failure.json")
            throw RecordingError.failed("Review export timing, arrow, blur or pixelation validation failed.")
        }
        return ["durationSeconds": actualDuration, "frames": frames,
                "comparison": "Edited frames compared with control-video.mp4, using the same annotated BGRA "
                    + "pipeline with a transparent empty-text layer. "
                    + "Source/control codec-color drift measured separately.",
                "result": "Passed: playable eight-second export; arrow, blur and pixelation present at 3.5s "
                    + "and absent at 1s / 6.5s. Raster changes exceed the inactive compression baseline."]
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let succeeded = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard succeeded else { throw RecordingError.failed("Review frame pixels are unavailable.") }
        return pixels
    }

    private func fractionOfRedPixels(_ pixels: [UInt8], in rect: CGRect, width: Int) -> Double {
        var red = 0
        var total = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let offset = (y * width + x) * 4
                if Int(pixels[offset]) > Int(pixels[offset + 1]) + 45,
                   Int(pixels[offset]) > Int(pixels[offset + 2]) + 45 { red += 1 }
                total += 1
            }
        }
        return Double(red) / Double(total)
    }

    private func difference(_ source: [UInt8], _ output: [UInt8], in rect: CGRect, width: Int) -> Double {
        var sum = 0
        var count = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let offset = (y * width + x) * 4
                for channel in 0..<3 {
                    sum += abs(Int(source[offset + channel]) - Int(output[offset + channel]))
                    count += 1
                }
            }
        }
        return Double(sum) / Double(count)
    }

    private func makeSource(at url: URL) async throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 960, AVVideoHeightKey: 540,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 3_000_000],
        ])
        let attributes = CVPixelBufferCreationAttributes(
            pixelFormatType: .init(rawValue: kCVPixelFormatType_32BGRA),
            size: .init(width: 960, height: 540))
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: attributes)
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        do {
            for index in 0..<192 {
                try Task.checkCancellation()
                let buffer = try makeFrame(index: index, attributes: attributes)
                try await receiver.append(buffer, with: CMTime(value: Int64(index), timescale: 24))
            }
            receiver.finish()
            writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 24))
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw writer.error ?? RecordingError.failed("Fixture video encoding failed.")
            }
        } catch {
            if writer.status == .writing { writer.cancelWriting() }
            throw error
        }
    }

    private func makeFrame(index: Int, attributes: CVPixelBufferCreationAttributes) throws -> CVReadOnlyPixelBuffer {
        let pixel = try CVMutablePixelBuffer(attributes)
        try pixel.withUnsafeBuffer { buffer in try drawFrame(index: index, into: buffer) }
        return CVReadOnlyPixelBuffer(pixel)
    }

    private func drawFrame(index: Int, into buffer: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 960, height: 540,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue) else {
            throw RecordingError.failed("Fixture drawing context failed.")
        }
        context.translateBy(x: 0, y: 540)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        NSColor(srgbRed: 0.06, green: 0.09, blue: 0.14, alpha: 1).setFill()
        CGRect(x: 0, y: 0, width: 960, height: 540).fill()
        NSColor(srgbRed: 0.11, green: 0.15, blue: 0.22, alpha: 1).setFill()
        NSBezierPath(roundedRect: CGRect(x: 40, y: 112, width: 880, height: 310), xRadius: 18, yRadius: 18).fill()
        draw("DEMO ACCOUNT", at: CGPoint(x: 60, y: 42), size: 28, color: .white, weight: .semibold)
        draw("Synthetic video fixture · no personal data", at: CGPoint(x: 60, y: 80), size: 16,
             color: NSColor(srgbRed: 0.65, green: 0.72, blue: 0.82, alpha: 1))
        draw("PROFILE", at: CGPoint(x: 80, y: 145), size: 14,
             color: NSColor(srgbRed: 0.45, green: 0.74, blue: 0.9, alpha: 1), weight: .semibold)
        draw("Demo Reviewer", at: CGPoint(x: 80, y: 206), size: 27, color: .white, weight: .semibold)
        draw("demo@example.invalid", at: CGPoint(x: 80, y: 260), size: 25, color: .white)
        draw("Active demo workspace", at: CGPoint(x: 550, y: 300), size: 21, color: .white, weight: .medium)
        NSColor(srgbRed: 0.19, green: 0.7, blue: 0.56, alpha: 1).setFill()
        NSBezierPath(ovalIn: CGRect(x: 550, y: 250, width: 22, height: 22)).fill()
        draw("Moving marker confirms playback", at: CGPoint(x: 60, y: 442), size: 16,
             color: NSColor(srgbRed: 0.65, green: 0.72, blue: 0.82, alpha: 1))
        NSColor(srgbRed: 0.19, green: 0.27, blue: 0.37, alpha: 1).setFill()
        NSBezierPath(roundedRect: CGRect(x: 60, y: 486, width: 735, height: 4), xRadius: 2, yRadius: 2).fill()
        NSColor.white.setFill()
        let motion = CGFloat(index) / 191
        NSBezierPath(ovalIn: CGRect(x: 60 + motion * 720, y: 477, width: 20, height: 20)).fill()
        draw(String(format: "%.2f s", Double(index) / 24), at: CGPoint(x: 814, y: 476), size: 18,
             color: .white, weight: .medium)
    }

    private func draw(_ text: String, at point: CGPoint, size: CGFloat, color: NSColor,
                      weight: NSFont.Weight = .regular) {
        (text as NSString).draw(at: point, withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
        ])
    }

    private func writeJSON(_ value: [String: Any], name: String) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    private func writeFailure(_ error: Error) {
        try? writeJSON(["error": error.localizedDescription], name: "review-failure.json")
        editor?.title = "Slightshot video editor · review failed (see review-failure.json)"
    }

    func applicationWillTerminate(_ notification: Notification) {
        reviewTask?.cancel()
        expiry?.invalidate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
