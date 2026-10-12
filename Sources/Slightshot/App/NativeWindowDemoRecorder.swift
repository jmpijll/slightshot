import AppKit
import ScreenCaptureKit

/// Records one explicitly selected synthetic review window, never the desktop.
final class NativeWindowDemoRecorder: NSObject {
    private let destination: URL
    private var stream: SCStream?
    private var recording: SCRecordingOutput?
    private var started = false
    private var result: Result<URL, Error>?
    private var ready: CheckedContinuation<Void, Error>?
    private var completion: CheckedContinuation<URL, Error>?

    init(destination: URL) { self.destination = destination }

    func start(window: NSWindow) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let target = content.windows.first(where: { $0.windowID == UInt32(window.windowNumber) }) else {
            throw CaptureError.failed("Native demo window is not shareable")
        }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let configuration = SCStreamConfiguration()
        let scale = window.screen?.backingScaleFactor ?? 2
        configuration.width = Int(window.frame.width * scale) / 2 * 2
        configuration.height = Int(window.frame.height * scale) / 2 * 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 5
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best
        configuration.capturesAudio = false
        configuration.captureMicrophone = false
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.stream = stream
        let output = SCRecordingOutputConfiguration()
        output.outputURL = destination
        output.videoCodecType = .h264
        output.outputFileType = .mp4
        let recording = SCRecordingOutput(configuration: output, delegate: self)
        self.recording = recording
        try stream.addRecordingOutput(recording)
        try await stream.startCapture()
        if let result { _ = try result.get() }
        if !started {
            try await withCheckedThrowingContinuation { ready = $0 }
        }
    }

    func stop() async throws -> URL {
        guard let stream else { throw CaptureError.failed("Demo recording never started") }
        do { try await stream.stopCapture() } catch { finish(.failure(error)) }
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { completion = $0 }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard self.result == nil else { return }
        self.result = result
        if case .failure(let error) = result { ready?.resume(throwing: error); ready = nil }
        completion?.resume(with: result)
        completion = nil
    }
}

extension NativeWindowDemoRecorder: SCRecordingOutputDelegate, SCStreamDelegate {
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in
            self?.started = true
            self?.ready?.resume()
            self?.ready = nil
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.finish(.success(self.destination))
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor [weak self] in self?.finish(.failure(error)) }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in self?.finish(.failure(error)) }
    }
}
