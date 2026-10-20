import AppKit
import AVFoundation
import ScreenCaptureKit

/// Owns ScreenCaptureKit and one private temporary directory. Its filter excludes
/// every Slightshot window, including the live Stop control and timer.
final class ScreenRecordingSession: NSObject {
    nonisolated static let directoryPrefix = "Slightshot-Recording-"
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
    private var hasStartedRecording = false
    private var streamError: Error?
    private var recovery: Task<Void, Never>?
    private let lock: FolderLock

    init(display: CapturedDisplay, selection: CGRect) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.directoryPrefix + UUID().uuidString, isDirectory: true)
        sourceURL = directory.appendingPathComponent("source.mp4")
        size = RecordingQuality.high.dimensions(for: display.pixelRect(for: selection).size)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        lock = try FolderLock(directory: directory)
        super.init()
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
        recovery?.cancel()
        try? FileManager.default.removeItem(at: directory)
        lock.release()
        stream = nil
        recording = nil
    }

    func recordingDidStart() {
        hasStartedRecording = true
        onStarted?()
    }

    func recordingDidFinish() { finish(.success(sourceURL)) }

    func recordingDidFail(_ error: Error) { finish(.failure(streamError ?? error)) }

    /// ScreenCaptureKit can report a stopped stream before its recording output
    /// finalises the movie, so a started recording waits for that verdict. No
    /// timer fails it: if the output never reports, a movie that has become
    /// playable is accepted instead.
    func streamDidStop(with error: Error, recheckEvery interval: Duration = .seconds(2)) {
        guard hasStartedRecording else { return finish(.failure(error)) }
        guard streamError == nil else { return }
        streamError = error
        isStopping = true
        recovery = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let session = self, session.result == nil else { return }
                if await session.playableDuration() != nil, session.result == nil {
                    session.finish(.success(session.sourceURL))
                }
            }
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard self.result == nil else { return }
        self.result = result
        recovery?.cancel()
        completion?.resume(with: result)
        completion = nil
        onFinished?(result)
    }
}

extension ScreenRecordingSession: SCRecordingOutputDelegate, SCStreamDelegate {
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in self?.recordingDidStart() }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in self?.recordingDidFinish() }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor [weak self] in self?.recordingDidFail(error) }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in self?.streamDidStop(with: error) }
    }
}

extension ScreenRecordingSession {
    /// Duration of the movie on disk, or nil unless it has a video track whose
    /// first frame decodes.
    func playableDuration() async -> TimeInterval? {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return nil }
        let asset = AVURLAsset(url: sourceURL)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty,
              let duration = try? await asset.load(.duration),
              duration.seconds.isFinite, duration.seconds > 0 else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceAfter = duration
        guard (try? await generator.image(at: .zero)) != nil else { return nil }
        return duration.seconds
    }

    /// Removes recording folders a crash or forced quit left behind. A folder is
    /// kept while another process holds its lock, or if it was created after `cutoff`.
    nonisolated static func removeAbandonedDirectories(prefix: String, in parent: URL, createdBefore cutoff: Date) {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.creationDateKey, .isDirectoryKey]
        guard let children = try? manager.contentsOfDirectory(at: parent, includingPropertiesForKeys: Array(keys))
        else { return }
        for child in children {
            let name = child.lastPathComponent
            guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil,
                  let values = try? child.resourceValues(forKeys: keys), values.isDirectory == true,
                  let created = values.creationDate, created < cutoff,
                  let lock = try? FolderLock(directory: child) else { continue }
            defer { lock.release() }
            do {
                try manager.removeItem(at: child)
            } catch {
                Log.capture.error("Abandoned recording not removed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// An exclusive `flock` on a marker file inside a temporary folder. The kernel
/// drops it when the owning process exits, so a held lock proves the folder is live.
nonisolated final class FolderLock: @unchecked Sendable {
    static let filename = ".slightshot-lock"
    private var descriptor: Int32

    /// Throws when another process already holds the folder.
    init(directory: URL) throws {
        let path = directory.appendingPathComponent(Self.filename).path
        descriptor = open(path, O_RDWR | O_CREAT | O_EXLOCK | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    func release() {
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
