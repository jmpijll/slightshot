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
        return "\(Int(size.width)) × \(Int(size.height)) · \(framesPerSecond) fps\n\(tradeoff)"
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
    /// Snapshot the editor's AppKit marks before entering the encoder worker.
    /// Only immutable cropped overlays cross the actor boundary.
    @MainActor static func save(source: URL, to destination: URL, quality: RecordingQuality,
                                annotations: [VideoAnnotation] = []) async throws {
        try Task.checkCancellation()
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
                                                       duration: duration.seconds)
        }
        try await savePrepared(source: source, to: destination, quality: quality, annotations: prepared)
    }

    /// AVFoundation's async providers apply backpressure without blocking the
    /// main actor. The output is staged alongside its destination; an existing
    /// file is replaced only after a complete, playable MP4 has been written.
    @concurrent private static func savePrepared(
        source: URL, to destination: URL, quality: RecordingQuality,
        annotations: [VideoFrameRenderer.PreparedAnnotation]
    ) async throws {
        try Task.checkCancellation()
        let stagingDirectory = destination.deletingLastPathComponent()
            .appendingPathComponent(".slightshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        // AVFoundation may create auxiliary .sb files beside its output. Keep
        // the entire job in a private directory so cancellation removes those
        // too, while the final move still stays on the destination filesystem.
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        let staged = stagingDirectory.appendingPathComponent("recording.mp4")

        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecordingError.empty
        }
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration.seconds > 0 else { throw RecordingError.empty }
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let sourceBounds = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform).integral
        let sourceSize = sourceBounds.size
        let size = quality.dimensions(for: sourceSize)
        let geometry = FrameGeometry(sourceBounds: sourceBounds,
                                     preferredTransform: preferredTransform, outputSize: size)
        let reader = try AVAssetReader(asset: asset)
        let output = compositionOutput(track: track, duration: duration, geometry: geometry, quality: quality,
                                       annotated: !annotations.isEmpty)
        let provider = reader.outputProvider(for: output)
        let writer = try AVAssetWriter(outputURL: staged, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let input = encodingInput(size: size, quality: quality)
        do {
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
            try reader.start()
            try writer.start()
            writer.startSession(atSourceTime: .zero)
            var frameCount = 0
            while let sample = try await provider.next() {
                try Task.checkCancellation()
                if let receiver {
                    try await receiver.append(sample)
                } else if let pixels, let processor,
                          let pixelSample = CMReadySampleBuffer<CVReadOnlyPixelBuffer>(sample),
                          sample.presentationTimeStamp.isNumeric {
                    guard let pool = pixels.pixelBufferPool else {
                        throw RecordingError.failed("The video encoder buffer pool is unavailable.")
                    }
                    let buffer = try processor.render(pixelSample, pool: pool)
                    try await pixels.append(CVReadOnlyPixelBuffer(buffer), with: sample.presentationTimeStamp)
                } else {
                    continue // Stream boundary markers contain no image.
                }
                frameCount += 1
            }
            guard frameCount > 0 else { throw RecordingError.empty }
            receiver?.finish()
            pixels?.finish()
            writer.endSession(atSourceTime: duration)
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
        } catch {
            reader.cancelReading()
            if writer.status == .writing { writer.cancelWriting() }
            throw error
        }
    }

    private struct FrameGeometry {
        let sourceBounds: CGRect
        let preferredTransform: CGAffineTransform
        let outputSize: CGSize
    }

    private static func compositionOutput(
        track: AVAssetTrack, duration: CMTime, geometry: FrameGeometry, quality: RecordingQuality, annotated: Bool
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
            frameDuration: CMTime(value: 1, timescale: quality.framesPerSecond),
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
