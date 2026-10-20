import AppKit
import AVFoundation
import ScreenCaptureKit

/// Bounded native review of unsaved-work protection. A synthetic movie stands in
/// for ScreenCaptureKit output; the coordinator, editor and quit prompt are production code.
enum LostWorkReview {
    static func run() {
        let app = SlightshotApplication.shared
        let index = CommandLine.arguments.firstIndex(of: "--lost-work-review")!
        let directory = CommandLine.arguments[safe: index + 1].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("build/lost-work-review", isDirectory: true)
        let delegate = LostWorkReviewDelegate(directory: directory)
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

private final class LostWorkReviewDelegate: NSObject, NSApplicationDelegate {
    private let directory: URL
    private var session: ScreenRecordingSession?
    private var steps: [[String: Any]] = []
    private var failures: [String] = []
    private var savePanelTicks = 0
    private var savePanelWatcher: Timer?

    init(directory: URL) {
        self.directory = directory
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do {
                try await review()
            } catch {
                failures.append(error.localizedDescription)
                writeReport(terminated: false)
                exit(EXIT_FAILURE)
            }
        }
        // Run-loop timers in common modes still fire while a modal panel blocks the main queue.
        let timeout = Timer(timeInterval: 120, repeats: false) { _ in
            MainActor.assumeIsolated { [self] in
                failures.append("Review timed out.")
                writeReport(terminated: false)
                exit(EXIT_FAILURE)
            }
        }
        RunLoop.main.add(timeout, forMode: .common)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        QuitGuard.shared.reply()
    }

    func applicationWillTerminate(_ notification: Notification) {
        let removed = session.map { !FileManager.default.fileExists(atPath: $0.directory.path) } ?? false
        check("Discard deleted the temporary recording before quitting", removed)
        writeReport(terminated: true)
    }

    private func review() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let screen = try require(NSScreen.main, "No display is available.")
        let display = CapturedDisplay(screen: screen, displayID: screen.displayID, image: try blankImage(), scale: 1)
        let session = try ScreenRecordingSession(display: display,
                                                 selection: CGRect(x: 0, y: 0, width: 960, height: 540))
        self.session = session
        RecordingCoordinator.shared.reviewAdopt(session)

        session.recordingDidStart()
        try await writeMovie(to: session.sourceURL)
        session.streamDidStop(with: SCStreamError(.userStopped))
        record("Simulated SCStream didStopWithError (userStopped) after recording started")
        try await Task.sleep(for: .milliseconds(300))
        session.recordingDidFinish()
        record("Simulated SCRecordingOutput didFinishRecording after the stream error")

        let editor = try await waitFor("the video editor") {
            NSApp.windows.first { $0 is VideoEditorWindow && $0.isVisible }
        }
        check("Editor opened with the recording after the stream error", true)
        try await Task.sleep(for: .milliseconds(800))
        try await capture("editor-after-stream-error.png")

        try await quit(answering: "Cancel", capture: "quit-prompt.png")
        check("Cancel kept Slightshot running with the editor open", editor.isVisible)
        check("Cancel kept the temporary recording",
              FileManager.default.fileExists(atPath: session.sourceURL.path))

        cancelSavePanel(afterCapturing: "save-panel-from-quit.png")
        try await quit(answering: "Save…", capture: nil)
        _ = try await waitFor("the editor after cancelling the save") { editor.isVisible ? editor : nil }
        try await Task.sleep(for: .milliseconds(300))
        check("Cancelling the save cancelled the quit and returned to the editor", editor.isVisible)

        try await quit(answering: "Discard Recording", capture: nil)
    }

    /// The prompt runs modally inside `terminate`, so the click comes from this task.
    private func quit(answering button: String, capture name: String?) async throws {
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
        let alert = try await waitFor("the quit prompt") { NSApp.modalWindow }
        try await Task.sleep(for: .milliseconds(600))
        if let name { try await capture(name) }
        NSApp.terminate(nil)
        check("A second quit while the prompt is open was ignored", NSApp.modalWindow === alert)
        let target = try require(buttons(in: alert.contentView).first { $0.title == button },
                                 "The quit prompt has no \(button) button.")
        record("Quit requested; prompt \"\(alert.title.isEmpty ? promptText(alert) : alert.title)\"; "
            + "automated click: \(button)")
        target.performClick(nil)
        try await Task.sleep(for: .milliseconds(500))
    }

    private func buttons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        return (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons(in:))
    }

    private func promptText(_ window: NSWindow) -> String {
        func texts(_ view: NSView) -> [String] {
            ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(texts)
        }
        return window.contentView.map(texts)?.first { !$0.isEmpty } ?? ""
    }

    private func waitFor<T>(_ name: String, _ probe: () -> T?) async throws -> T {
        for _ in 0..<100 {
            if let value = probe() { return value }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw RecordingError.failed("Timed out waiting for \(name).")
    }

    /// The save panel runs modally inside a main-queue job, so this watcher uses
    /// a common-mode timer and callback-based capture instead of the review task.
    private func cancelSavePanel(afterCapturing name: String) {
        let timer = Timer(timeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated { [self] in
                guard NSApp.windows.contains(where: { $0 is NSSavePanel && $0.isVisible }) else { return }
                savePanelTicks += 1
                guard savePanelTicks == 5 else { return }
                savePanelWatcher?.invalidate()
                startCapture(name) { error in
                    RunLoop.main.perform(inModes: [.common]) {
                        MainActor.assumeIsolated { [self] in
                            if let error {
                                failures.append(error.localizedDescription)
                            } else {
                                record("Captured \(name) (ScreenCaptureKit, Slightshot windows only)")
                            }
                            NSApp.terminate(nil)
                            check("A second quit while the save panel is open was ignored",
                                  NSApp.windows.contains { $0 is NSSavePanel && $0.isVisible })
                            record("Automated click: Cancel in the save panel")
                            let panel = NSApp.windows.first { $0 is NSSavePanel && $0.isVisible } as? NSSavePanel
                            panel?.cancel(nil)
                        }
                    }
                }
            }
        }
        savePanelWatcher = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func capture(_ name: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            startCapture(name) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        record("Captured \(name) (ScreenCaptureKit, Slightshot windows only)")
    }

    /// Captures only Slightshot's own windows, so no other screen content is included.
    private func startCapture(_ name: String, completion: @escaping @Sendable (Error?) -> Void) {
        let windows = NSApp.windows.filter { $0.isVisible && $0.frame.width > 1 }
        guard let screen = windows.first?.screen ?? NSScreen.main else {
            return completion(RecordingError.failed("No screen for capture."))
        }
        let union = windows.map(\.frame).reduce(windows[0].frame) { $0.union($1) }.insetBy(dx: -24, dy: -24)
            .intersection(screen.frame)
        let sourceRect = CGRect(x: union.minX - screen.frame.minX, y: screen.frame.maxY - union.maxY,
                                width: union.width, height: union.height)
        let scale = screen.backingScaleFactor
        let displayID = screen.displayID
        let processID = ProcessInfo.processInfo.processIdentifier
        let destination = directory.appendingPathComponent(name)
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            guard let content, let display = content.displays.first(where: { $0.displayID == displayID }) else {
                return completion(error ?? RecordingError.failed("The review display is unavailable."))
            }
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = sourceRect
            configuration.width = Int(sourceRect.width * scale)
            configuration.height = Int(sourceRect.height * scale)
            configuration.showsCursor = false
            let filter = SCContentFilter(display: display, including: content.applications.filter {
                $0.processID == processID
            }, exceptingWindows: [])
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                guard let image,
                      let output = CGImageDestinationCreateWithURL(destination as CFURL,
                                                                   "public.png" as CFString, 1, nil)
                else { return completion(error ?? RecordingError.failed("The capture could not be encoded.")) }
                CGImageDestinationAddImage(output, image, nil)
                completion(CGImageDestinationFinalize(output) ? nil : RecordingError.failed("PNG write failed."))
            }
        }
    }

    private func writeMovie(to url: URL) async throws {
        let width = 960, height = 540, framesPerSecond = 15, seconds = 4
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? RecordingError.empty }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(framesPerSecond * seconds) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            let pool = try require(adaptor.pixelBufferPool, "The movie buffer pool is unavailable.")
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            let pixels = try require(buffer, "A movie frame could not be allocated.")
            CVPixelBufferLockBaseAddress(pixels, [])
            let context = try require(CGContext(
                data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                "A movie frame context could not be created.")
            drawFrame(frame, of: framesPerSecond * seconds, in: context, size: CGSize(width: width, height: height))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            guard adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame),
                                                                       timescale: CMTimeScale(framesPerSecond))) else {
                throw writer.error ?? RecordingError.empty
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? RecordingError.empty }
        record("Wrote a synthetic 4-second 960x540 movie as the recording")
    }

    private func drawFrame(_ frame: Int, of count: Int, in context: CGContext, size: CGSize) {
        context.setFillColor(NSColor(srgbRed: 0.10, green: 0.14, blue: 0.22, alpha: 1).cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        let progress = CGFloat(frame) / CGFloat(count - 1)
        context.setFillColor(NSColor.systemTeal.cgColor)
        context.fillEllipse(in: CGRect(x: 80 + progress * (size.width - 240), y: 200, width: 80, height: 80))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let title = "Synthetic review recording · stream stopped by the system"
        title.draw(at: CGPoint(x: 60, y: 420), withAttributes: [
            .font: NSFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: NSColor.white,
        ])
        String(format: "%.1f s", Double(frame) / 15).draw(at: CGPoint(x: 60, y: 90), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 28, weight: .regular), .foregroundColor: NSColor.white,
        ])
        NSGraphicsContext.restoreGraphicsState()
    }

    private func blankImage() throws -> CGImage {
        let context = try require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  "The display stand-in could not be created.")
        return try require(context.makeImage(), "The display stand-in could not be created.")
    }

    private func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw RecordingError.failed(message) }
        return value
    }

    private func record(_ step: String) {
        steps.append(["step": step])
        Log.app.info("Lost-work review: \(step, privacy: .public)")
    }

    private func check(_ name: String, _ passed: Bool) {
        steps.append(["check": name, "passed": passed])
        if !passed { failures.append(name) }
    }

    private func writeReport(terminated: Bool) {
        let report: [String: Any] = [
            "fixture": "--lost-work-review: synthetic movie in a real ScreenRecordingSession folder; "
                + "ScreenCaptureKit callbacks simulated; coordinator, editor, quit prompt and save panel "
                + "are production code",
            "sourceCommit": ProcessInfo.processInfo.environment["SLIGHTSHOT_REVIEW_SOURCE_COMMIT"] ?? "unspecified",
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "steps": steps,
            "terminatedThroughQuitGuard": terminated,
            "passed": failures.isEmpty && terminated,
            "failures": failures,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: directory.appendingPathComponent("validation.json"), options: .atomic)
    }
}
