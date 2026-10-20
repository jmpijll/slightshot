import AppKit
import AVFoundation
import Testing
@testable import Slightshot

@MainActor
struct QuitGuardTests {
    private final class Log {
        var events: [String] = []
        var replies: [Bool] = []
    }

    private func quitGuard(_ work: UnsavedWork?, choose choice: QuitChoice, saves: Bool = true,
                           copies: Bool = true, log: Log) -> QuitGuard {
        QuitGuard(
            unsavedWork: { work },
            ask: { _ in log.events.append("ask"); return choice },
            saveRecording: { log.events.append("save"); return saves },
            copyAnnotations: { log.events.append("copy"); return copies },
            discardRecording: { log.events.append("discard") }
        )
    }

    private func settle(_ log: Log) async {
        for _ in 0..<20 where log.replies.isEmpty { await Task.yield() }
    }

    @Test func nothingUnsavedQuitsWithoutAsking() {
        let log = Log()
        #expect(quitGuard(nil, choose: .cancel, log: log).reply { log.replies.append($0) } == .terminateNow)
        #expect(log.events.isEmpty)
    }

    @Test(arguments: [UnsavedWork.recording(canSave: true), .recording(canSave: false), .annotations])
    func cancelKeepsTheAppRunning(work: UnsavedWork) async {
        let log = Log()
        #expect(quitGuard(work, choose: .cancel, log: log).reply { log.replies.append($0) } == .terminateCancel)
        await settle(log)
        #expect(log.events == ["ask"])
        #expect(log.replies.isEmpty)
    }

    @Test(arguments: [true, false])
    func saveQuitsOnlyAfterTheRecordingIsSaved(saved: Bool) async {
        let log = Log()
        let reply = quitGuard(.recording(canSave: true), choose: .save, saves: saved, log: log)
            .reply { log.replies.append($0) }
        #expect(reply == .terminateLater)
        await settle(log)
        #expect(log.events == ["ask", "save"])
        #expect(log.replies == [saved])
    }

    @Test(arguments: [UnsavedWork.recording(canSave: true), .recording(canSave: false)])
    func discardRemovesTheRecordingBeforeQuitting(work: UnsavedWork) async {
        let log = Log()
        #expect(quitGuard(work, choose: .discard, log: log).reply { log.replies.append($0) } == .terminateLater)
        await settle(log)
        #expect(log.events == ["ask", "discard"])
        #expect(log.replies == [true])
    }

    @Test func discardedAnnotationsQuitImmediately() {
        let log = Log()
        #expect(quitGuard(.annotations, choose: .discard, log: log).reply { log.replies.append($0) } == .terminateNow)
        #expect(log.events == ["ask"])
    }

    @Test(arguments: [true, false])
    func copyQuitsOnlyAfterTheCaptureIsCopied(copied: Bool) {
        let log = Log()
        let reply = quitGuard(.annotations, choose: .copy, copies: copied, log: log).reply { log.replies.append($0) }
        #expect(reply == (copied ? .terminateNow : .terminateCancel))
        #expect(log.events == ["ask", "copy"])
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
}

@MainActor
@Suite(.serialized)
struct RecordingSessionCompletionTests {
    private struct StreamStopped: Error {}

    @Test func streamErrorWaitsForTheRecordingToFinish() throws {
        let session = try ScreenRecordingSession(display: display(), selection: CGRect(x: 0, y: 0, width: 64, height: 64))
        defer { session.cleanUp() }
        var results: [Result<URL, Error>] = []
        session.onFinished = { results.append($0) }
        session.recordingDidStart()
        session.streamDidStop(with: StreamStopped())
        #expect(results.isEmpty)
        session.recordingDidFinish()
        #expect(results.count == 1)
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
        let staging = try folder(RecordingExport.stagingPrefix + UUID().uuidString,
                                 created: launch.addingTimeInterval(-3600))

        ScreenRecordingSession.removeAbandonedDirectories(prefix: prefix, in: parent, createdBefore: launch)

        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(FileManager.default.fileExists(atPath: active.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(FileManager.default.fileExists(atPath: staging.path))
        ScreenRecordingSession.removeAbandonedDirectories(prefix: RecordingExport.stagingPrefix, in: parent,
                                                          createdBefore: launch)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    private func writeMovie(to url: URL, seconds: Int) async throws {
        let size = 64
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size, AVVideoHeightKey: size,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size, kCVPixelBufferHeightKey as String: size,
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let frames = seconds * 10
        for frame in 0...frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            let pool = try #require(adaptor.pixelBufferPool)
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 20 % 255), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }
}

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
