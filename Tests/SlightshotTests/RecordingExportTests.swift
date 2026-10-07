import AVFoundation
import Testing
@testable import Slightshot

@Suite(.serialized)
struct RecordingExportTests {
    @Test func qualityDimensionsPreserveAspectAndNeverUpscale() {
        let source = CGSize(width: 3025, height: 1981)
        for quality in RecordingQuality.allCases {
            let size = quality.dimensions(for: source)
            #expect(size.width <= source.width && size.height <= source.height)
            #expect(max(size.width, size.height) <= quality.maximumDimension)
            #expect(Int(size.width).isMultiple(of: 2) && Int(size.height).isMultiple(of: 2))
            #expect(abs(size.width / size.height - source.width / source.height) < 0.005)
        }
        #expect(RecordingQuality.high.dimensions(for: CGSize(width: 101, height: 79)) == CGSize(width: 100, height: 78))
    }

    @Test func realExportsArePlayableAndApplyQuality() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4")
        try await createMovingVideo(at: source)
        var fileSizes: [RecordingQuality: Int] = [:]
        for quality in RecordingQuality.allCases {
            let destination = directory.appendingPathComponent("\(quality.rawValue).mp4")
            try await RecordingExport.save(source: source, to: destination, quality: quality)
            let asset = AVURLAsset(url: destination)
            #expect(try await asset.load(.isPlayable))
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            let dimensions = try await track.load(.naturalSize)
            #expect(dimensions == quality.dimensions(for: CGSize(width: 2048, height: 1200)))
            let rate = try await track.load(.nominalFrameRate)
            #expect(abs(rate - Float(quality.framesPerSecond)) < 0.1)
            let duration = try await asset.load(.duration)
            #expect(abs(duration.seconds - 2) < 0.1)
            let descriptions = try await track.load(.formatDescriptions)
            #expect(descriptions.first.map { CMFormatDescriptionGetMediaSubType($0) } == kCMVideoCodecType_H264)
            fileSizes[quality] = try Data(contentsOf: destination).count
        }
        #expect(try #require(fileSizes[.compact]) < #require(fileSizes[.high]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .contains(where: { $0.hasPrefix(".slightshot-") }) == false)
    }

    @Test func cancellationAndBadSourcePreserveExistingDestination() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("existing.mp4")
        let original = Data("Keep the existing file".utf8)
        try original.write(to: destination)
        let task = Task {
            try await RecordingExport.save(source: directory.appendingPathComponent("missing.mp4"),
                                           to: destination, quality: .compact)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: destination) == original)
        await #expect(throws: (any Error).self) {
            try await RecordingExport.save(source: directory.appendingPathComponent("missing.mp4"),
                                           to: destination, quality: .high)
        }
        #expect(try Data(contentsOf: destination) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["existing.mp4"])

        let source = directory.appendingPathComponent("source.mp4")
        try await createMovingVideo(at: source)
        let activeExport = Task {
            try await RecordingExport.save(source: source, to: destination, quality: .high)
        }
        var didStartWriting = false
        for _ in 0..<500 {
            let stagedDirectories = try FileManager.default.contentsOfDirectory(at: directory,
                                                                                includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(".slightshot-") }
            if stagedDirectories.contains(where: {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("recording.mp4").path)
            }) {
                didStartWriting = true
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(didStartWriting)
        activeExport.cancel()
        await #expect(throws: CancellationError.self) { try await activeExport.value }
        #expect(try Data(contentsOf: destination) == original)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(remaining == ["existing.mp4", "source.mp4"])
    }

    @Test func successfulExportAtomicallyReplacesExistingFile() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4")
        let destination = directory.appendingPathComponent("existing.mp4")
        try await createMovingVideo(at: source)
        try Data("Old file".utf8).write(to: destination)
        try await RecordingExport.save(source: source, to: destination, quality: .compact)
        #expect(try await AVURLAsset(url: destination).load(.isPlayable))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            == ["existing.mp4", "source.mp4"])
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    /// A moving, detailed fixture catches an ineffective quality slider and
    /// wrong fps/duration without needing Screen Recording permission or a UI.
    private func createMovingVideo(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 2048, AVVideoHeightKey: 1200,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 18_000_000],
        ])
        let attributes = CVPixelBufferCreationAttributes(pixelFormatType: .init(rawValue: kCVPixelFormatType_32BGRA),
                                                        size: .init(width: 2048, height: 1200))
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: attributes)
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<60 {
            let pixel = try CVMutablePixelBuffer(attributes)
            pixel.withUnsafeBuffer { buffer in
                CVPixelBufferLockBaseAddress(buffer, [])
                defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
                let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 2048, height: 1200,
                                        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                                            | CGImageAlphaInfo.premultipliedFirst.rawValue)!
                for y in stride(from: 0, to: 1200, by: 16) {
                    for x in stride(from: 0, to: 2048, by: 16) {
                        context.setFillColor(red: CGFloat((x + frame * 11) % 256) / 255,
                                             green: CGFloat((y + frame * 7) % 256) / 255,
                                             blue: CGFloat(((x / 7) ^ (y / 5) ^ (frame * 3)) % 256) / 255, alpha: 1)
                        context.fill(CGRect(x: x, y: y, width: 16, height: 16))
                    }
                }
            }
            try await receiver.append(CVReadOnlyPixelBuffer(pixel), with: CMTime(value: Int64(frame), timescale: 30))
        }
        receiver.finish()
        writer.endSession(atSourceTime: CMTime(value: 2, timescale: 1))
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }
}
