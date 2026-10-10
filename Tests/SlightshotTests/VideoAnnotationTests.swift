import AppKit
import AVFoundation
import Testing
@testable import Slightshot

@MainActor @Suite(.serialized)
struct VideoAnnotationTests {
    @Test func rangesAreFiniteClampedAndHalfOpen() {
        let mark = annotation(.rectangle(CGRect(x: 0, y: 0, width: 20, height: 20)))
        var value = VideoAnnotation(annotation: mark, start: 1, end: 3)
        #expect(value.id == mark.id)
        #expect(!value.isActive(at: 0.999))
        #expect(value.isActive(at: 1))
        #expect(value.isActive(at: 2.999))
        #expect(!value.isActive(at: 3))
        #expect(!value.isActive(at: .nan))
        value.setRange(start: -4, end: 100, duration: 5)
        #expect(value.start == 0 && value.end == 5 && value.duration == 5)
        value.setRange(start: 4, end: 1, duration: 5)
        #expect(value.start == 4 && value.end == 4)
        value.start = .infinity
        value.end = .nan
        #expect(value.start == 0 && value.end == 0)
        let invalid = VideoAnnotation(annotation: mark, start: .nan, end: -.infinity)
        #expect(invalid.duration == 0)
        let clipped = VideoAnnotation(annotation: mark, start: 4, end: 6).clamped(to: 2)
        #expect(clipped.start == 2 && clipped.end == 2)
    }

    @Test func preparedExportMatchesScreenshotDrawingAndEffectOrder() throws {
        let source = try fixture(frame: 0)
        let shapes: [Annotation.Shape] = [
            .stroke(points: [CGPoint(x: 10, y: 100), CGPoint(x: 60, y: 120), CGPoint(x: 85, y: 95)]),
            .line(from: CGPoint(x: 170, y: 20), to: CGPoint(x: 270, y: 20)),
            .arrow(from: CGPoint(x: 170, y: 45), to: CGPoint(x: 270, y: 65)),
            .rectangle(CGRect(x: 165, y: 75, width: 55, height: 40)),
            .text("Timed mark", origin: CGPoint(x: 10, y: 135)),
            .step(number: 2, center: CGPoint(x: 260, y: 110)),
            .blur(CGRect(x: 10, y: 10, width: 90, height: 55)),
            .pixelate(CGRect(x: 55, y: 105, width: 60, height: 40)),
        ]
        let values = shapes.map { VideoAnnotation(annotation: annotation($0), start: 0.25, end: 0.75) }
        let prepared = try VideoFrameRenderer.prepare(values, size: CGSize(width: 320, height: 180), duration: 1)
        let context = try #require(VideoFrameRenderer.makeContext(size: CGSize(width: 320, height: 180)))
        for time in [0.0, 0.25, 0.5, 0.75, 0.9] {
            let preview = try #require(VideoFrameRenderer.render(image: source, at: time, annotations: values))
            let export = try VideoFrameRenderer.render(image: source, at: time, prepared: prepared, context: context)
            for y in stride(from: 0, to: 180, by: 3) {
                for x in stride(from: 0, to: 320, by: 3) {
                    let expected = pixel(preview, x: x, y: y)
                    let actual = pixel(export, x: x, y: y)
                    #expect(zip(expected, actual).allSatisfy { abs($0 - $1) <= 2 },
                            "Preview/export mismatch at \(time)s, \(x),\(y): \(expected) / \(actual)")
                }
            }
        }
    }

    @Test func realExportsShowTimedMarksAndFreshPrivacyPixelsAtEveryQuality() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4")
        try await createVideo(at: source)
        let sourceBytes = try Data(contentsOf: source)
        let annotations = [
            VideoAnnotation(annotation: annotation(.line(from: CGPoint(x: 175, y: 140),
                                                          to: CGPoint(x: 290, y: 140))), start: 0.25, end: 0.75),
            VideoAnnotation(annotation: annotation(.blur(CGRect(x: 20, y: 20, width: 60, height: 55))),
                            start: 0.25, end: 0.75),
            VideoAnnotation(annotation: annotation(.pixelate(CGRect(x: 85, y: 20, width: 55, height: 55))),
                            start: 0.25, end: 0.75),
        ]
        for quality in RecordingQuality.allCases {
            let destination = directory.appendingPathComponent("\(quality.rawValue).mp4")
            try await RecordingExport.save(source: source, to: destination, quality: quality, annotations: annotations)
            let asset = AVURLAsset(url: destination)
            #expect(try await asset.load(.isPlayable))
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            #expect(try await track.load(.naturalSize) == CGSize(width: 320, height: 180))
            #expect(abs(try await asset.load(.duration).seconds - 1) < 0.04)
            let before = try await Self.frame(in: destination, at: 0.1)
            let redPhase = try await Self.frame(in: destination, at: 0.4)
            let bluePhase = try await Self.frame(in: destination, at: 0.6)
            let after = try await Self.frame(in: destination, at: 0.9)
            // Hardware/software H.264 encoders can map the gray fixture's
            // background differently (the hosted runner produces red=60).
            // Compare the line site with untouched background in the same frame
            // so this tests timing, independently of the encoder's gray level.
            #expect(abs(pixel(before, x: 230, y: 140)[0] - pixel(before, x: 230, y: 155)[0]) < 20)
            #expect(pixel(redPhase, x: 230, y: 140)[0] > 200)
            #expect(pixel(bluePhase, x: 230, y: 140)[0] > 200)
            #expect(abs(pixel(after, x: 230, y: 140)[0] - pixel(after, x: 230, y: 155)[0]) < 20)
            // The current frame changes from red detail to blue detail midway.
            // Both privacy tools must process the new pixels, never a cached frame.
            for x in [50, 110] {
                let red = pixel(redPhase, x: x, y: 45)
                let blue = pixel(bluePhase, x: x, y: 45)
                #expect(red[0] > red[2] + 50)
                #expect(blue[2] > blue[0] + 50)
                #expect(red[0] > 55 && red[0] < 210)
                #expect(blue[2] > 55 && blue[2] < 210)
            }
            // Output quality still selects the actual frame cadence.
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            let provider = reader.outputProvider(for: output)
            try reader.start()
            var timestamps: [Double] = []
            while let sample = try await provider.next() {
                if sample.contentType == .dataBuffer, sample.presentationTimeStamp.isNumeric {
                    timestamps.append(sample.presentationTimeStamp.seconds)
                }
            }
            timestamps.sort()
            #expect(abs(timestamps.count - Int(quality.framesPerSecond)) <= 1)
            for (first, second) in zip(timestamps, timestamps.dropFirst()) {
                #expect(abs(second - first - 1 / Double(quality.framesPerSecond)) < 0.001)
            }
        }
        #expect(try Data(contentsOf: source) == sourceBytes)
    }

    @Test func cancelledAnnotatedExportRetainsDestinationAndSource() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4")
        try await createVideo(at: source, frameCount: 300)
        let sourceBytes = try Data(contentsOf: source)
        let destination = directory.appendingPathComponent("existing.mp4")
        let original = Data("Original destination".utf8)
        try original.write(to: destination)
        let effect = VideoAnnotation(annotation: annotation(.blur(CGRect(x: 0, y: 0, width: 320, height: 180))),
                                     start: 0, end: 10)
        let task = Task {
            try await RecordingExport.save(source: source, to: destination, quality: .high, annotations: [effect])
        }
        var didEncodeFrames = false
        for _ in 0..<500 {
            let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            if children.contains(where: {
                guard $0.lastPathComponent.hasPrefix(".slightshot-"),
                      let files = try? FileManager.default.contentsOfDirectory(at: $0,
                                                                                includingPropertiesForKeys: nil) else {
                    return false
                }
                return files.contains { file in
                    guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                          let size = attributes[.size] as? NSNumber else { return false }
                    return size.intValue > 0
                }
            }) { didEncodeFrames = true; break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(didEncodeFrames, "Cancel must interrupt an encoder that has already produced media data.")
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: destination) == original)
        #expect(try Data(contentsOf: source) == sourceBytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
                == ["existing.mp4", "source.mp4"])
    }

    private func annotation(_ shape: Annotation.Shape) -> Annotation {
        Annotation(shape: shape, color: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), lineWidth: 8)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func fixture(frame: Int) throws -> CGImage {
        let context = try #require(VideoFrameRenderer.makeContext(size: CGSize(width: 320, height: 180)))
        context.setFillColor(CGColor(gray: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        for y in stride(from: 10, to: 85, by: 2) {
            for x in stride(from: 10, to: 150, by: 2) {
                let channel: CGFloat = ((x + y) / 2).isMultiple(of: 2) ? 0 : 1
                context.setFillColor(red: frame < 15 ? channel : 0, green: 0,
                                     blue: frame < 15 ? 0 : channel, alpha: 1)
                context.fill(CGRect(x: x, y: 180 - y - 2, width: 2, height: 2))
            }
        }
        return try #require(context.makeImage())
    }

    private func createVideo(at url: URL, frameCount: Int = 30) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 5_000_000],
        ])
        let attributes = CVPixelBufferCreationAttributes(pixelFormatType: .init(rawValue: kCVPixelFormatType_32BGRA),
                                                        size: .init(width: 320, height: 180))
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: attributes)
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        for index in 0..<frameCount {
            let image = try fixture(frame: index)
            let buffer = try CVMutablePixelBuffer(attributes)
            try buffer.withUnsafeBuffer { raw in
                CVPixelBufferLockBaseAddress(raw, [])
                defer { CVPixelBufferUnlockBaseAddress(raw, []) }
                let context = try #require(CGContext(data: CVPixelBufferGetBaseAddress(raw), width: 320, height: 180,
                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(raw),
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: 320, height: 180))
            }
            let pixel = CVReadOnlyPixelBuffer(buffer)
            try await RecordingExport.appendWhenReady {
                try receiver.appendImmediately(pixel, with: CMTime(value: Int64(index), timescale: 30))
            }
        }
        receiver.finish()
        writer.endSession(atSourceTime: CMTime(value: Int64(frameCount), timescale: 30))
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }

    @concurrent private static func frame(in url: URL, at seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 15)
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> [Int] {
        guard let crop = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let color = NSBitmapImageRep(cgImage: crop).colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB) else { return [] }
        return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
            .map { Int(max(0, min(255, ($0 * 255).rounded()))) }
    }
}
