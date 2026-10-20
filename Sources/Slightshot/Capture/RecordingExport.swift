import AVFoundation
import CoreImage

/// Save-time choices. Capture always keeps the best source so changing this
/// slider after stopping can never reduce the quality of a later retry.
nonisolated enum RecordingQuality: Int, CaseIterable, Sendable {
    case compact, balanced, high

    var title: String {
        switch self {
        case .compact: "Small & fast"
        case .balanced: "Balanced"
        case .high: "High quality"
        }
    }

    var framesPerSecond: Int32 {
        switch self {
        case .compact: 15
        case .balanced: 24
        case .high: 30
        }
    }

    var maximumDimension: CGFloat {
        switch self {
        case .compact: 1280
        case .balanced: 1920
        case .high: 4096
        }
    }

    func frameDuration(forSourceMinimum source: CMTime) -> CMTime {
        let limit = CMTime(value: 1, timescale: framesPerSecond)
        // A slower source must keep its own cadence instead of rounding its
        // frames onto a faster grid. Unknown timing still uses the quality cap.
        guard source.isNumeric, source.seconds > 0 else { return limit }
        return CMTimeCompare(source, limit) > 0 ? source : limit
    }

    func dimensions(for source: CGSize) -> CGSize {
        let scale = min(1, maximumDimension / max(source.width, source.height))
        // H.264 chroma samples require even dimensions. Round inward so neither
        // the capture nor the export accidentally includes pixels outside it.
        return CGSize(width: max(2, floor(source.width * scale / 2) * 2),
                      height: max(2, floor(source.height * scale / 2) * 2))
    }

    func bitrate(for size: CGSize) -> Int {
        let bitsPerPixel: Double = switch self {
        case .compact: 0.08
        case .balanced: 0.14
        case .high: 0.24
        }
        return max(150_000, Int(size.width * size.height * Double(framesPerSecond) * bitsPerPixel))
    }

    func detail(for source: CGSize) -> String {
        let size = dimensions(for: source)
        let tradeoff: String = switch self {
        case .compact: "Prioritize smaller files and quicker saving"
        case .balanced: "Balance detail and file size"
        case .high: "Preserve more detail and smoother motion"
        }
        return "\(Int(size.width)) × \(Int(size.height)) · up to \(framesPerSecond) fps\n\(tradeoff)"
    }
}

nonisolated enum RecordingError: LocalizedError {
    case failed(String)
    case empty
    case displayDisconnected

    var errorDescription: String? {
        switch self {
        case .failed(let reason): "The recording could not be saved: \(reason)"
        case .empty: "No video frames were recorded. Try recording for a little longer."
        case .displayDisconnected: "The selected display is no longer available."
        }
    }
}

nonisolated enum RecordingExport {
    static let stagingPrefix = ".slightshot-"
    private static let stagingParentsKey = "RecordingExportStagingParents"

    /// Folders where an export staged its output and has not yet cleaned up.
    /// Launch sweeps them, since a crash can leave staging beside any destination.
    static var stagingParents: [URL] {
        (UserDefaults.standard.stringArray(forKey: stagingParentsKey) ?? []).map { URL(fileURLWithPath: $0) }
    }

    static func forgetStagingParent(_ parent: URL) {
        let paths = UserDefaults.standard.stringArray(forKey: stagingParentsKey) ?? []
        UserDefaults.standard.set(paths.filter { $0 != parent.path }, forKey: stagingParentsKey)
    }

    static func rememberStagingParent(_ parent: URL) {
        let paths = UserDefaults.standard.stringArray(forKey: stagingParentsKey) ?? []
        guard !paths.contains(parent.path) else { return }
        UserDefaults.standard.set(paths + [parent.path], forKey: stagingParentsKey)
    }

    /// Snapshot the editor's AppKit marks before entering the encoder worker.
    /// Only immutable cropped overlays cross the actor boundary.
    /// A trim keeps only its range, starting at zero; marks outside it are dropped.
    @MainActor static func save(source: URL, to destination: URL, quality: RecordingQuality,
                                annotations: [VideoAnnotation] = [], trim: VideoTrim? = nil) async throws {
        try Task.checkCancellation()
        try validateDestination(source: source, destination: destination)
        let annotations = trim.map { trim in annotations.compactMap { $0.trimmed(to: trim) } } ?? annotations
        var prepared: [VideoFrameRenderer.PreparedAnnotation] = []
        if !annotations.isEmpty {
            let asset = AVURLAsset(url: source)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw RecordingError.empty
            }
            let duration = try await asset.load(.duration)
            guard duration.isNumeric, duration.seconds > 0 else { throw RecordingError.empty }
            let naturalSize = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let sourceBounds = CGRect(origin: .zero, size: naturalSize).applying(transform).integral
            prepared = try VideoFrameRenderer.prepare(annotations, size: sourceBounds.size,
                                                       duration: trim?.duration ?? duration.seconds)
        }
        try await savePrepared(source: source, to: destination, quality: quality, trim: trim,
                               annotations: prepared)
    }

    private static func validateDestination(source: URL, destination: URL) throws {
        let original = source.standardizedFileURL.resolvingSymlinksInPath()
        let target = destination.standardizedFileURL.resolvingSymlinksInPath()
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        let originalID = (try? original.resourceValues(forKeys: keys))?.fileResourceIdentifier
        let targetID = (try? target.resourceValues(forKeys: keys))?.fileResourceIdentifier
        // Resource identity catches hard links and case aliases on insensitive
        // volumes without treating distinct files on sensitive volumes as equal.
        let sameFile = originalID.map { identifier in
            targetID.map { identifier.isEqual($0) } ?? false
        } ?? false
        guard original != target, !sameFile else {
            throw RecordingError.failed("Choose a save location different from the temporary recording. "
                + "The original video has been preserved.")
        }
    }

    /// AVFoundation may create auxiliary .sb files beside its output. Keep the
    /// entire job in a private, locked directory so cancellation removes those
    /// too, while the final move still stays on the destination filesystem.
    private static func makeStagingDirectory(beside destination: URL) throws -> (URL, () -> Void) {
        let parent = destination.deletingLastPathComponent()
        let directory = parent.appendingPathComponent(stagingPrefix + UUID().uuidString, isDirectory: true)
        rememberStagingParent(parent)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let lock = try FolderLock(directory: directory)
            return (directory, {
                try? FileManager.default.removeItem(at: directory)
                lock.release()
                forgetStagingParent(parent)
            })
        } catch {
            try? FileManager.default.removeItem(at: directory)
            forgetStagingParent(parent)
            throw error
        }
    }

    /// Reader and writer backpressure keep encoding off the main actor.
    /// The output is staged alongside its destination; an existing
    /// file is replaced only after a complete, playable MP4 has been written.
    @concurrent private static func savePrepared(
        source: URL, to destination: URL, quality: RecordingQuality, trim: VideoTrim?,
        annotations: [VideoFrameRenderer.PreparedAnnotation]
    ) async throws {
        try Task.checkCancellation()
        let (stagingDirectory, removeStaging) = try makeStagingDirectory(beside: destination)
        defer { removeStaging() }
        let staged = stagingDirectory.appendingPathComponent("recording.mp4")

        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecordingError.empty
        }
        let sourceDuration = try await asset.load(.duration)
        guard sourceDuration.isNumeric, sourceDuration.seconds > 0 else { throw RecordingError.empty }
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let (keptAsset, keptTrack) = try await kept(trim, of: asset, track: track, duration: sourceDuration)
        let duration = try await keptAsset.load(.duration)
        let frameDuration = quality.frameDuration(forSourceMinimum: try await track.load(.minFrameDuration))
        let sourceBounds = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform).integral
        let sourceSize = sourceBounds.size
        let size = quality.dimensions(for: sourceSize)
        let geometry = FrameGeometry(sourceBounds: sourceBounds,
                                     preferredTransform: preferredTransform, outputSize: size)
        let reader = try AVAssetReader(asset: keptAsset)
        let output = compositionOutput(track: keptTrack, duration: duration, geometry: geometry,
                                       frameDuration: frameDuration, annotated: !annotations.isEmpty)
        let provider = reader.outputProvider(for: output)
        let writer = try AVAssetWriter(outputURL: staged, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let input = encodingInput(size: size, quality: quality)
        let cancellation = ExportCancellation(reader: reader, writer: writer)
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                // Reader and writer providers each apply backpressure. A single
                // source frame and a recycled encoder buffer are in flight at once.
                let receiver = annotations.isEmpty ? writer.inputReceiver(for: input) : nil
                let attributes = CVPixelBufferCreationAttributes(
                    pixelFormatType: .init(rawValue: kCVPixelFormatType_32BGRA),
                    size: .init(width: Int(size.width), height: Int(size.height)))
                let pixels = annotations.isEmpty ? nil
                    : writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: attributes)
                let processor = annotations.isEmpty ? nil
                    : try FrameProcessor(sourceSize: sourceSize, outputSize: size, annotations: annotations)
                try cancellation.start()
                var frameCount = 0
                while let sample = try await provider.next() {
                    try Task.checkCancellation()
                    if let receiver {
                        try await appendWhenReady {
                            try cancellation.append { try receiver.appendImmediately(sample) }
                        }
                    } else if let pixels, let processor,
                              let pixelSample = CMReadySampleBuffer<CVReadOnlyPixelBuffer>(sample),
                              sample.presentationTimeStamp.isNumeric {
                        guard let pool = pixels.pixelBufferPool else {
                            throw RecordingError.failed("The video encoder buffer pool is unavailable.")
                        }
                        let buffer = try processor.render(pixelSample, pool: pool)
                        let frame = CVReadOnlyPixelBuffer(buffer)
                        try await appendWhenReady {
                            try cancellation.append {
                                try pixels.appendImmediately(frame, with: sample.presentationTimeStamp)
                            }
                        }
                    } else {
                        continue // Stream boundary markers contain no image.
                    }
                    frameCount += 1
                }
                guard frameCount > 0 else { throw RecordingError.empty }
                try cancellation.beginFinishing(at: duration) {
                    receiver?.finish()
                    pixels?.finish()
                }
                try await finishAndCommit(writer: writer, staged: staged, destination: destination)
            } onCancel: {
                // Cancel the reader's suspended next() and release the writer.
                // Append backpressure is a cancellable Swift wait above.
                // cancelWriting() blocks until native cleanup finishes, so keep
                // that work off the caller of the editor's Cancel action.
                DispatchQueue.global(qos: .userInitiated).async { cancellation.cancel() }
            }
        } catch {
            cancellation.cancel()
            // Native providers can report an interrupted media operation when
            // cancellation wakes their wait. Keep the editor's Cancel behavior.
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    /// A trimmed export reads a composition holding only the kept range at time
    /// zero, so encoding and annotation timing match a whole-recording export.
    private static func kept(_ trim: VideoTrim?, of asset: AVAsset, track: AVAssetTrack,
                             duration: CMTime) async throws -> (AVAsset, AVAssetTrack) {
        guard let trim = trim.map({ VideoTrim(start: $0.start, end: $0.end, recording: duration.seconds) }),
              !trim.isWhole(of: duration.seconds) else { return (asset, track) }
        let composition = AVMutableComposition()
        guard let keptTrack = composition.addMutableTrack(withMediaType: .video,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RecordingError.failed("The trimmed video could not be prepared.")
        }
        let range = CMTimeRange(start: CMTime(seconds: trim.start, preferredTimescale: 600),
                                end: CMTime(seconds: trim.end, preferredTimescale: 600))
        try keptTrack.insertTimeRange(range, of: track, at: .zero)
        keptTrack.preferredTransform = try await track.load(.preferredTransform)
        return (composition, keptTrack)
    }

    /// The native async receiver can miss its readiness notification on macOS
    /// 27, leaving append suspended even when the encoder is ready (including
    /// after cancellation). Use its documented immediate backpressure result
    /// instead. A false result never consumed the frame; an error is propagated.
    nonisolated(nonsending) static func appendWhenReady(_ append: () throws -> Bool) async throws {
        while true {
            try Task.checkCancellation()
            if try append() { return }
            // Yield the worker while the encoder drains; cancellation wakes
            // this cooperative wait without relying on a native continuation.
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private static func finishAndCommit(writer: AVAssetWriter, staged: URL, destination: URL) async throws {
        await writer.finishWriting()
        try Task.checkCancellation()
        guard writer.status == .completed else {
            throw writer.error ?? RecordingError.failed("Video encoding failed.")
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: destination)
        }
    }

    /// The ownership is immutable; only AVFoundation's thread-safe cancellation
    /// entry points run concurrently with the worker's normal sequential calls.
    private enum ExportPhase { case configuring, writing, finishing, cancelled }

    private final class ExportCancellation: @unchecked Sendable {
        let reader: AVAssetReader
        let writer: AVAssetWriter
        private let lock = NSLock()
        private var phase = ExportPhase.configuring

        init(reader: AVAssetReader, writer: AVAssetWriter) {
            self.reader = reader
            self.writer = writer
        }

        func cancel() {
            lock.withLock {
                guard phase != .finishing, phase != .cancelled else { return }
                phase = .cancelled
                if reader.status == .reading { reader.cancelReading() }
                if writer.status == .writing { writer.cancelWriting() }
            }
        }

        func start() throws {
            try lock.withLock {
                try Task.checkCancellation()
                guard phase != .cancelled else { throw CancellationError() }
                try reader.start()
                try writer.start()
                writer.startSession(atSourceTime: .zero)
                phase = .writing
            }
        }

        func append(_ operation: () throws -> Bool) throws -> Bool {
            try lock.withLock {
                try Task.checkCancellation()
                guard phase == .writing else { throw CancellationError() }
                return try operation()
            }
        }

        func beginFinishing(at duration: CMTime, finishInputs: () -> Void) throws {
            try lock.withLock {
                try Task.checkCancellation()
                guard phase == .writing else { throw CancellationError() }
                guard writer.status == .writing else {
                    throw writer.error ?? RecordingError.failed("Video encoding failed.")
                }
                // No native cancellation may race finish()/endSession(). Once
                // this short flush starts, cancellation still prevents commit.
                phase = .finishing
                finishInputs()
                writer.endSession(atSourceTime: duration)
            }
        }
    }

    private struct FrameGeometry {
        let sourceBounds: CGRect
        let preferredTransform: CGAffineTransform
        let outputSize: CGSize
    }

    private static func compositionOutput(
        track: AVAssetTrack, duration: CMTime, geometry: FrameGeometry, frameDuration: CMTime, annotated: Bool
    ) -> AVAssetReaderVideoCompositionOutput {
        // Apply marks at source resolution, then resize the finished frame. This
        // preserves the screenshot tools' source-pixel stroke and privacy sizes.
        let bounds = geometry.sourceBounds
        let decodeSize = annotated ? bounds.size : geometry.outputSize
        let transform = geometry.preferredTransform
            .concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
            .concatenating(CGAffineTransform(scaleX: decodeSize.width / bounds.width,
                                             y: decodeSize.height / bounds.height))
        var layer = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
        layer.setTransform(transform, at: .zero)
        let instruction = AVVideoCompositionInstruction(configuration: .init(
            layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layer)],
            timeRange: CMTimeRange(start: .zero, duration: duration)
        ))
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: annotated
                ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        output.videoComposition = AVVideoComposition(configuration: .init(
            frameDuration: frameDuration,
            instructions: [instruction], renderSize: decodeSize,
            sourceTrackIDForFrameTiming: kCMPersistentTrackID_Invalid
        ))
        return output
    }

    private static func encodingInput(size: CGSize, quality: RecordingQuality) -> AVAssetWriterInput {
        AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: quality.bitrate(for: size),
                AVVideoExpectedSourceFrameRateKey: Int(quality.framesPerSecond),
                AVVideoMaxKeyFrameIntervalKey: Int(quality.framesPerSecond) * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
    }

    private struct FrameProcessor {
        let sourceSize: CGSize
        let outputSize: CGSize
        let annotations: [VideoFrameRenderer.PreparedAnnotation]
        let drawingContext: CGContext
        let imageContext: CIContext
        let colorSpace: CGColorSpace

        init(sourceSize: CGSize, outputSize: CGSize,
             annotations: [VideoFrameRenderer.PreparedAnnotation]) throws {
            self.sourceSize = sourceSize
            self.outputSize = outputSize
            self.annotations = annotations
            guard let context = VideoFrameRenderer.makeContext(size: sourceSize) else {
                throw RecordingError.failed("The video drawing surface could not be allocated.")
            }
            drawingContext = context
            colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            imageContext = CIContext(options: [.workingColorSpace: colorSpace, .cacheIntermediates: false])
        }

        func render(_ sample: CMReadySampleBuffer<CVReadOnlyPixelBuffer>,
                    pool: CVMutablePixelBuffer.Pool) throws -> CVMutablePixelBuffer {
            let rendered: CGImage = try autoreleasepool {
                let image = sample.content.withUnsafeBuffer { buffer in
                    imageContext.createCGImage(CIImage(cvPixelBuffer: buffer),
                                               from: CGRect(origin: .zero, size: sourceSize),
                                               format: .RGBA8, colorSpace: colorSpace)
                }
                guard let image else { throw RecordingError.failed("A video frame could not be decoded.") }
                return try VideoFrameRenderer.render(image: image, at: sample.presentationTimeStamp.seconds,
                                                     prepared: annotations, context: drawingContext)
            }
            let buffer = try pool.makeMutablePixelBuffer()
            try buffer.withUnsafeBuffer { raw in
                CVPixelBufferLockBaseAddress(raw, [])
                defer { CVPixelBufferUnlockBaseAddress(raw, []) }
                guard let context = CGContext(data: CVPixelBufferGetBaseAddress(raw),
                    width: Int(outputSize.width), height: Int(outputSize.height), bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(raw), space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue) else {
                    throw RecordingError.failed("An encoded frame could not be allocated.")
                }
                context.interpolationQuality = .high
                context.draw(rendered, in: CGRect(origin: .zero, size: outputSize))
            }
            return buffer
        }
    }
}
