import AVFoundation

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
    /// AVFoundation's async providers apply backpressure without blocking the
    /// main actor. The output is staged alongside its destination; an existing
    /// file is replaced only after a complete, playable MP4 has been written.
    @concurrent static func save(source: URL, to destination: URL, quality: RecordingQuality) async throws {
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
        let sourceSize = try await track.load(.naturalSize)
        let size = quality.dimensions(for: sourceSize)
        let transform = try await track.load(.preferredTransform)
            .concatenating(CGAffineTransform(scaleX: size.width / sourceSize.width,
                                             y: size.height / sourceSize.height))

        var layer = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
        layer.setTransform(transform, at: .zero)
        let instruction = AVVideoCompositionInstruction(configuration: .init(
            layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layer)],
            timeRange: CMTimeRange(start: .zero, duration: duration)
        ))
        let composition = AVVideoComposition(configuration: .init(
            frameDuration: CMTime(value: 1, timescale: quality.framesPerSecond),
            instructions: [instruction], renderSize: size,
            sourceTrackIDForFrameTiming: kCMPersistentTrackID_Invalid
        ))
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        output.videoComposition = composition
        let provider = reader.outputProvider(for: output)

        let writer = try AVAssetWriter(outputURL: staged, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
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
        let receiver = writer.inputReceiver(for: input)
        do {
            try reader.start()
            try writer.start()
            writer.startSession(atSourceTime: .zero)
            var frameCount = 0
            while let sample = try await provider.next() {
                try Task.checkCancellation()
                try await receiver.append(sample)
                frameCount += 1
            }
            guard frameCount > 0 else { throw RecordingError.empty }
            receiver.finish()
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
}
