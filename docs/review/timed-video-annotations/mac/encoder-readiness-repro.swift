import AVFoundation
import Foundation

final class NativeState: @unchecked Sendable {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    init(_ writer: AVAssetWriter, _ input: AVAssetWriterInput) { self.writer = writer; self.input = input }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

@main struct Repro {
    static func main() async throws {
        let mode = CommandLine.arguments[1]
        let jobs = Int(CommandLine.arguments[2])!
        for index in 0..<jobs { try await encode(mode: mode, index: index) }
    }

    @concurrent static func encode(mode: String, index: Int) async throws {
        let destination = URL(fileURLWithPath: "/tmp/slightshot-receiver-\(mode)-\(index).mp4")
        try? FileManager.default.removeItem(at: destination)
        defer { try? FileManager.default.removeItem(at: destination) }
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 5_000_000],
        ])
        let attributes = CVPixelBufferCreationAttributes(pixelFormatType: .init(rawValue: kCVPixelFormatType_32BGRA),
                                                        size: .init(width: 320, height: 180))
        let pixels = mode.hasPrefix("pixels") ? writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: attributes) : nil
        let samples = mode.hasPrefix("samples") ? writer.inputReceiver(for: input) : nil
        let pool = try CVMutablePixelBuffer.Pool(pixelBufferAttributes: attributes)
        let state = NativeState(writer, input)
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { log("WATCH \(mode) job \(index) ready=\(state.input.isReadyForMoreMediaData) status=\(state.writer.status.rawValue) error=\(String(describing: state.writer.error))") }
        timer.resume()
        defer { timer.cancel() }
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<300 {
            let buffer = try pool.makeMutablePixelBuffer()
            buffer.withUnsafeBuffer { raw in
                CVPixelBufferLockBaseAddress(raw, [])
                defer { CVPixelBufferUnlockBaseAddress(raw, []) }
                memset(CVPixelBufferGetBaseAddress(raw)!, Int32(frame % 255), CVPixelBufferGetDataSize(raw))
            }
            let pixel = CVReadOnlyPixelBuffer(buffer)
            let time = CMTime(value: Int64(frame), timescale: 30)
            log("\(mode) job \(index) append \(frame) begin status \(writer.status.rawValue)")
            if let pixels {
                if mode.hasSuffix("immediate") {
                    while try !pixels.appendImmediately(pixel, with: time) { try await Task.sleep(for: .milliseconds(1)) }
                } else { try await pixels.append(pixel, with: time) }
            }
            if let samples {
                let sample = CMReadySampleBuffer(pixelBuffer: pixel, presentationTimeStamp: time,
                                                 duration: CMTime(value: 1, timescale: 30))
                if mode.hasSuffix("immediate") {
                    while try !samples.appendImmediately(CMReadySampleBuffer(sample)) { try await Task.sleep(for: .milliseconds(1)) }
                } else { try await samples.append(CMReadySampleBuffer(sample)) }
            }
            log("\(mode) job \(index) append \(frame) complete")
        }
        pixels?.finish()
        samples?.finish()
        writer.endSession(atSourceTime: CMTime(value: 10, timescale: 1))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error! }
        log("\(mode) job \(index) complete")
    }
}
