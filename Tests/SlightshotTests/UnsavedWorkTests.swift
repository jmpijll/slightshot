import AppKit
import AVFoundation
import Testing
@testable import Slightshot

@MainActor
struct QuitGuardTests {
    private final class Log {
        var events: [String] = []
    }

    private func quitGuard(_ work: UnsavedWork?, choose choice: QuitChoice, saves: Bool = true,
                           copies: Bool = true, log: Log) -> QuitGuard {
        QuitGuard(
            unsavedWork: { work },
            ask: { _ in log.events.append("ask"); return choice },
            saveRecording: { log.events.append("save"); await Task.yield(); return saves },
            copyAnnotations: { log.events.append("copy"); return copies },
            discardRecording: { log.events.append("discard") },
            quit: { log.events.append("quit") }
        )
    }

    private func settle(_ guardian: QuitGuard) async {
        for _ in 0..<50 where guardian.isPending { await Task.yield() }
    }

    @Test func nothingUnsavedQuitsWithoutAsking() {
        let log = Log()
        #expect(quitGuard(nil, choose: .cancel, log: log).reply() == .terminateNow)
        #expect(log.events.isEmpty)
    }

    @Test(arguments: [UnsavedWork.recording(canSave: true), .recording(canSave: false), .annotations])
    func cancelKeepsTheAppRunning(work: UnsavedWork) {
        let log = Log()
        let guardian = quitGuard(work, choose: .cancel, log: log)
        #expect(guardian.reply() == .terminateCancel)
        #expect(log.events == ["ask"])
        #expect(!guardian.isPending)
    }

    @Test(arguments: [true, false])
    func saveCancelsTheQuitAndQuitsAgainOnlyAfterSaving(saved: Bool) async {
        let log = Log()
        let guardian = quitGuard(.recording(canSave: true), choose: .save, saves: saved, log: log)
        #expect(guardian.reply() == .terminateCancel)
        #expect(guardian.isPending)
        #expect(guardian.reply() == .terminateCancel, "A repeated quit during the save is refused")
        await settle(guardian)
        #expect(!guardian.isPending)
        #expect(log.events == (saved ? ["ask", "save", "quit"] : ["ask", "save"]))
    }

    @Test func aQuitArrivingWhileThePromptIsOpenIsRefused() {
        let log = Log()
        var nested: NSApplication.TerminateReply?
        var guardian: QuitGuard!
        guardian = QuitGuard(
            unsavedWork: { .annotations },
            ask: { _ in
                log.events.append("ask")
                nested = guardian.reply()
                return .discard
            },
            saveRecording: { false }, copyAnnotations: { false }, discardRecording: {}, quit: {})
        #expect(guardian.reply() == .terminateNow)
        #expect(nested == .terminateCancel)
        #expect(log.events == ["ask"])
    }

    @Test(arguments: [UnsavedWork.recording(canSave: true), .recording(canSave: false)])
    func discardRemovesTheRecordingBeforeQuitting(work: UnsavedWork) {
        let log = Log()
        #expect(quitGuard(work, choose: .discard, log: log).reply() == .terminateNow)
        #expect(log.events == ["ask", "discard"])
    }

    @Test func discardedAnnotationsQuitImmediately() {
        let log = Log()
        #expect(quitGuard(.annotations, choose: .discard, log: log).reply() == .terminateNow)
        #expect(log.events == ["ask"])
    }

    @Test(arguments: [true, false])
    func copyQuitsOnlyAfterTheCaptureIsCopied(copied: Bool) {
        let log = Log()
        let reply = quitGuard(.annotations, choose: .copy, copies: copied, log: log).reply()
        #expect(reply == (copied ? .terminateNow : .terminateCancel))
        #expect(log.events == ["ask", "copy"])
    }

    /// AppKit ignores the delegate for a second `terminate` while one is being
    /// decided, so this runs the real application subclass in its own process.
    @Test func repeatedQuitRequestsInARealApplicationWaitForTheDecision() throws {
        let executable = Bundle(for: ProbeLocator.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("Slightshot")
        try #require(FileManager.default.isExecutableFile(atPath: executable.path))
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--quit-guard-probe"]
        // Xcode and SwiftPM builds place Sparkle differently; reuse the copy this test loaded.
        let sparkle = try #require(Bundle(identifier: "org.sparkle-project.Sparkle"))
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["DYLD_FRAMEWORK_PATH": sparkle.bundleURL.deletingLastPathComponent().path]) { _, new in new }
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, "\(text)")
        #expect(text.contains("QUIT-GUARD-PROBE PASS"), "\(text)")
    }

    @Test func annotatedOverlayIsUnsavedWork() throws {
        let presentation = HiddenOverlayPresentation()
        let coordinator = OverlayCoordinator(presentation: presentation)
        coordinator.present([try display()])
        let view = try #require(presentation.views.first)
        #expect(coordinator.unsavedWork == nil)
        view.annotations = [Annotation(shape: .line(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 10)),
                                       color: .red, lineWidth: 4)]
        #expect(coordinator.unsavedWork == .annotations)
        coordinator.dismiss()
        #expect(coordinator.unsavedWork == nil)
    }

    @Test func textStillBeingTypedIsUnsavedWork() throws {
        let presentation = HiddenOverlayPresentation()
        let coordinator = OverlayCoordinator(presentation: presentation)
        coordinator.present([try display()])
        let view = try #require(presentation.views.first)
        let entry = TextEntryView(origin: CGPoint(x: 20, y: 20), color: .red, fontSize: 18, maxWidth: 200)
        view.textEntry = entry
        entry.string = "   "
        #expect(coordinator.unsavedWork == nil)
        entry.string = "Draft"
        #expect(coordinator.unsavedWork == .annotations)
        coordinator.dismiss()
    }
}

@MainActor
@Suite(.serialized)
struct RecordingSessionCompletionTests {
    private struct StreamStopped: Error {}

    @Test func aLateRecordingSuccessWinsOverTheStreamError() async throws {
        let session = try ScreenRecordingSession(display: display(), selection: CGRect(x: 0, y: 0, width: 64, height: 64))
        defer { session.cleanUp() }
        var results: [Result<URL, Error>] = []
        session.onFinished = { results.append($0) }
        session.recordingDidStart()
        try Data("still being written".utf8).write(to: session.sourceURL)
        session.streamDidStop(with: StreamStopped(), recheckEvery: .milliseconds(50))
        try await Task.sleep(for: .milliseconds(600))
        #expect(results.isEmpty, "An unfinished movie is never failed on a timer")
        session.recordingDidFinish()
        #expect(results.count == 1)
        #expect(try results.first?.get() == session.sourceURL)
    }

    @Test func aPlayableMovieIsKeptWhenTheOutputNeverReports() async throws {
        let session = try ScreenRecordingSession(display: display(), selection: CGRect(x: 0, y: 0, width: 64, height: 64))
        defer { session.cleanUp() }
        var results: [Result<URL, Error>] = []
        session.onFinished = { results.append($0) }
        session.recordingDidStart()
        try await writeMovie(to: session.sourceURL, seconds: 1)
        session.streamDidStop(with: StreamStopped(), recheckEvery: .milliseconds(50))
        for _ in 0..<100 where results.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        #expect(try results.first?.get() == session.sourceURL)
    }

    @Test func streamErrorBeforeRecordingStartsFailsImmediately() throws {
        let session = try ScreenRecordingSession(display: display(), selection: CGRect(x: 0, y: 0, width: 64, height: 64))
        defer { session.cleanUp() }
        var results: [Result<URL, Error>] = []
        session.onFinished = { results.append($0) }
        session.streamDidStop(with: StreamStopped())
        #expect(results.count == 1)
        #expect(throws: StreamStopped.self) { try results.first?.get() }
    }

    @Test func onlyAPlayableMovieCountsAsARecording() async throws {
        let session = try ScreenRecordingSession(display: display(), selection: CGRect(x: 0, y: 0, width: 64, height: 64))
        defer { session.cleanUp() }
        #expect(await session.playableDuration() == nil)
        try Data("not a movie".utf8).write(to: session.sourceURL)
        #expect(await session.playableDuration() == nil)
        try FileManager.default.removeItem(at: session.sourceURL)
        try await writeMovie(to: session.sourceURL, seconds: 1)
        let duration = try #require(await session.playableDuration())
        #expect(duration > 0.5)

        var movie = try Data(contentsOf: session.sourceURL)
        let samples = try #require(movie.firstRange(of: Data("mdat".utf8)))
        let index = try #require(movie.firstRange(of: Data("moov".utf8), in: samples.upperBound..<movie.endIndex))
        let payload = samples.upperBound + 16..<index.lowerBound - 4
        movie.replaceSubrange(payload, with: Data(count: payload.count))
        try movie.write(to: session.sourceURL)
        #expect(try await AVURLAsset(url: session.sourceURL).load(.duration).seconds > 0.5,
                "The movie still claims a duration")
        #expect(await session.playableDuration() == nil, "but no frame decodes")
    }

    @Test func launchRemovesOnlyAbandonedRecordingFolders() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let launch = Date()
        func folder(_ name: String, created: Date) throws -> URL {
            let url = parent.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            try Data([1]).write(to: url.appendingPathComponent("source.mp4"))
            try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: url.path)
            return url
        }
        let prefix = ScreenRecordingSession.directoryPrefix
        let abandoned = try folder(prefix + UUID().uuidString, created: launch.addingTimeInterval(-3600))
        let active = try folder(prefix + UUID().uuidString, created: launch.addingTimeInterval(1))
        let unrelated = try folder(prefix + "notes", created: launch.addingTimeInterval(-3600))
        let owned = try folder(prefix + UUID().uuidString, created: launch.addingTimeInterval(-3600))
        let ownerLock = try FolderLock(directory: owned)
        let staging = try folder(RecordingExport.stagingPrefix + UUID().uuidString,
                                 created: launch.addingTimeInterval(-3600))

        ScreenRecordingSession.removeAbandonedDirectories(prefix: prefix, in: parent, createdBefore: launch)

        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(FileManager.default.fileExists(atPath: active.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(FileManager.default.fileExists(atPath: owned.path), "A folder whose lock is held is live")
        #expect(FileManager.default.fileExists(atPath: staging.path))
        ownerLock.release()
        ScreenRecordingSession.removeAbandonedDirectories(prefix: prefix, in: parent, createdBefore: launch)
        #expect(!FileManager.default.fileExists(atPath: owned.path))
        ScreenRecordingSession.removeAbandonedDirectories(prefix: RecordingExport.stagingPrefix, in: parent,
                                                          createdBefore: launch)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test func anExportRemembersItsStagingFolderUntilItFinishes() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let source = parent.appendingPathComponent("source.mp4")
        try await writeMovie(to: source, seconds: 2)
        let export = Task {
            try await RecordingExport.save(source: source, to: parent.appendingPathComponent("saved.mp4"),
                                           quality: .high)
        }
        var remembered = false
        for _ in 0..<200 where !remembered {
            remembered = RecordingExport.stagingParents.contains { $0.path == parent.path }
            if !remembered { try await Task.sleep(for: .milliseconds(5)) }
        }
        try await export.value
        #expect(remembered, "A running export records where it stages")
        #expect(!RecordingExport.stagingParents.contains { $0.path == parent.path })
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path)
            .contains { $0.hasPrefix(RecordingExport.stagingPrefix) } == false)
    }

    @Test func aLiveSessionFolderSurvivesTheSweep() throws {
        let session = try ScreenRecordingSession(display: display(), selection: CGRect(x: 0, y: 0, width: 64, height: 64))
        defer { session.cleanUp() }
        try Data([1]).write(to: session.sourceURL)
        ScreenRecordingSession.removeAbandonedDirectories(
            prefix: ScreenRecordingSession.directoryPrefix, in: session.directory.deletingLastPathComponent(),
            createdBefore: .distantFuture)
        #expect(FileManager.default.fileExists(atPath: session.sourceURL.path))
    }

    private func writeMovie(to url: URL, seconds: Int) async throws {
        let size = 64
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size, AVVideoHeightKey: size,
        ])
        let attributes = CVPixelBufferCreationAttributes(pixelFormatType: .init(rawValue: kCVPixelFormatType_32BGRA),
                                                         size: .init(width: size, height: size))
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: attributes)
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * 10) {
            let pixel = try CVMutablePixelBuffer(attributes)
            pixel.withUnsafeBuffer { buffer in
                CVPixelBufferLockBaseAddress(buffer, [])
                defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
                memset(CVPixelBufferGetBaseAddress(buffer), Int32(frame * 20 % 255), CVPixelBufferGetDataSize(buffer))
            }
            let buffer = CVReadOnlyPixelBuffer(pixel)
            try await RecordingExport.appendWhenReady {
                try receiver.appendImmediately(buffer, with: CMTime(value: CMTimeValue(frame), timescale: 10))
            }
        }
        receiver.finish()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(seconds), timescale: 1))
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }
}

private final class ProbeLocator {}

@MainActor
private final class HiddenOverlayPresentation: OverlayPresentation {
    private(set) var views: [OverlayView] = []
    func show(_ views: [OverlayView], focused: OverlayView?) { self.views = views }
    func focus(_ view: OverlayView) {}
    func hide() {}
    func close() { views.removeAll() }
}

@MainActor
private func display() throws -> CapturedDisplay {
    let screen = try #require(NSScreen.main)
    let context = try #require(CGContext(data: nil, width: 320, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
    return CapturedDisplay(screen: screen, displayID: 0, image: try #require(context.makeImage()), scale: 1)
}
