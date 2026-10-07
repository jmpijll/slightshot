import AppKit
import ScreenCaptureKit

/// Owns ScreenCaptureKit and one private temporary directory. Its filter excludes
/// every Slightshot window, including the live Stop control and timer.
final class ScreenRecordingSession: NSObject {
    let directory: URL
    let sourceURL: URL
    let size: CGSize
    var onStarted: (() -> Void)?
    var onFinished: ((Result<URL, Error>) -> Void)?

    private var stream: SCStream?
    private var recording: SCRecordingOutput?
    private var result: Result<URL, Error>?
    private var completion: CheckedContinuation<URL, Error>?
    private var isStopping = false

    init(display: CapturedDisplay, selection: CGRect) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Slightshot-Recording-\(UUID().uuidString)", isDirectory: true)
        sourceURL = directory.appendingPathComponent("source.mp4")
        size = RecordingQuality.high.dimensions(for: display.pixelRect(for: selection).size)
        super.init()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }

    var duration: TimeInterval { recording?.recordedDuration.seconds ?? 0 }

    func start(displayID: CGDirectDisplayID, selection: CGRect, includeCursor: Bool) async throws {
        guard ScreenRecordingPermission.isGranted else { throw CaptureError.permissionDenied }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw RecordingError.displayDisconnected
        }
        try Task.checkCancellation()
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        // sourceRect uses display points with its origin at the top-left, exactly
        // the same coordinates as the region-selection overlay.
        configuration.sourceRect = selection
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 5
        configuration.showsCursor = includeCursor
        configuration.capturesAudio = false
        configuration.captureMicrophone = false
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.scalesToFit = true

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.stream = stream
        let outputConfiguration = SCRecordingOutputConfiguration()
        outputConfiguration.outputURL = sourceURL
        outputConfiguration.videoCodecType = .h264
        outputConfiguration.outputFileType = .mp4
        let recording = SCRecordingOutput(configuration: outputConfiguration, delegate: self)
        self.recording = recording
        try stream.addRecordingOutput(recording)
        try await stream.startCapture()
        if case .failure(let error) = result { throw error }
    }

    func stop() async {
        guard !isStopping, let stream else { return }
        isStopping = true
        do {
            try await stream.stopCapture()
        } catch {
            finish(.failure(error))
        }
    }

    func waitUntilFinished() async throws -> URL {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { completion = $0 }
    }

    /// Also covers startup failures, before ScreenCaptureKit can notify its delegate.
    func failed(_ error: Error) { finish(.failure(error)) }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
        stream = nil
        recording = nil
    }

    private func finish(_ result: Result<URL, Error>) {
        guard self.result == nil else { return }
        self.result = result
        completion?.resume(with: result)
        completion = nil
        onFinished?(result)
    }
}

extension ScreenRecordingSession: SCRecordingOutputDelegate, SCStreamDelegate {
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in self?.onStarted?() }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.finish(.success(self.sourceURL))
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor [weak self] in self?.finish(.failure(error)) }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in self?.finish(.failure(error)) }
    }
}
