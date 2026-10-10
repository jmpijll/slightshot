import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// Selection → live recording → Stop → timed annotations → save-time quality. Keeping the frozen
/// screenshot overlay out of this lifecycle ensures the recorded screen is live.
final class RecordingCoordinator {
    static let shared = RecordingCoordinator()
    private enum Phase { case starting, recording, stopping, editing, saving }
    private var phase: Phase?
    private var session: ScreenRecordingSession?
    private var recordingPanel: RecordingPanel?
    private var recordingOutline: RecordingOutlinePanel?
    private var savePanel: NSSavePanel?
    private var exportPanel: RecordingExportPanel?
    private var editor: VideoEditorWindow?
    private var startTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var exportTask: Task<Void, Error>?
    private var isTerminating = false

    private init() {}
    var isBusy: Bool { phase != nil }

    func begin(display: CapturedDisplay, selection: CGRect) {
        guard !isBusy, !isTerminating else { return }
        let selection = selection.intersection(CGRect(origin: .zero, size: display.frame.size))
        guard selection.width >= 8, selection.height >= 8 else { return }
        do {
            let session = try ScreenRecordingSession(display: display, selection: selection)
            self.session = session
            phase = .starting
            session.onStarted = { [weak self, weak session] in
                guard let self, let session, self.session === session,
                      self.phase == .starting, !self.isTerminating else { return }
                self.phase = .recording
                self.recordingPanel?.started { [weak session] in session?.duration ?? 0 }
                Log.debug("Live recording started", Log.capture)
            }
            session.onFinished = { [weak self, weak session] result in
                guard let self, let session, self.session === session, !self.isTerminating else { return }
                self.finished(result, session: session)
            }
            let panel = RecordingPanel(screen: display.screen, selection: selection) { [weak self] in self?.stop() }
            recordingPanel = panel
            let outline = RecordingOutlinePanel(screen: display.screen, selection: selection)
            recordingOutline = outline
            outline.orderFrontRegardless()
            panel.orderFrontRegardless()
            // ScreenCaptureKit obtains fresh content only after the overlay has
            // closed. Its filter also excludes the app's live recording panel.
            let includeCursor = Settings.shared.captureCursor
            startTask = Task {
                do {
                    try await session.start(displayID: display.displayID, selection: selection,
                                            includeCursor: includeCursor)
                } catch {
                    session.failed(error)
                }
            }
        } catch {
            OutputService.presentError(error.localizedDescription)
        }
    }

    private func stop() {
        guard phase == .recording, let session else { return }
        phase = .stopping
        closeRecordingPanel()
        Task { await session.stop() }
    }

    private func finished(_ result: Result<URL, Error>, session: ScreenRecordingSession) {
        closeRecordingPanel()
        phase = .saving
        saveTask = Task { [weak self] in
            guard let self else { return }
            await self.startTask?.value
            await session.stop()
            guard !self.isTerminating else { return }
            switch result {
            case .success(let source):
                do {
                    let asset = AVURLAsset(url: source)
                    let duration = try await asset.load(.duration)
                    guard duration.seconds.isFinite, duration.seconds > 0 else { throw RecordingError.empty }
                    self.presentEditor(source: source, size: session.size, duration: duration.seconds)
                    return
                } catch { OutputService.presentError(error.localizedDescription) }
            case .failure(let error):
                if error is CancellationError { break }
                if case CaptureError.permissionDenied = error {
                    ScreenRecordingPermission.request()
                    ScreenRecordingPermission.presentDeniedAlert()
                } else {
                    OutputService.presentError(error.localizedDescription)
                }
            }
            self.reset()
        }
    }

    private func presentEditor(source: URL, size: CGSize, duration: TimeInterval) {
        phase = .editing
        let window = VideoEditorWindow(source: source, duration: duration, sourceSize: size)
        window.onSave = { [weak self] annotations in
            guard let self, self.phase == .editing, !self.isTerminating else { return }
            self.phase = .saving
            self.editor?.orderOut(nil)
            self.saveTask = Task {
                if await self.chooseDestination(source: source, size: size, annotations: annotations) {
                    self.reset()
                } else if !self.isTerminating {
                    self.phase = .editing
                    self.editor?.makeKeyAndOrderFront(nil)
                }
            }
        }
        window.onDiscard = { [weak self] in
            guard let self, self.phase == .editing else { return }
            if self.shouldDiscard() { self.reset() }
        }
        editor = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func chooseDestination(source: URL, size: CGSize, annotations: [VideoAnnotation]) async -> Bool {
        var proposedURL: URL?
        while !isTerminating, !Task.isCancelled {
            let panel = NSSavePanel()
            panel.title = "Save recording"
            panel.prompt = "Save"
            panel.allowedContentTypes = [.mpeg4Movie]
            panel.canCreateDirectories = true
            panel.directoryURL = proposedURL?.deletingLastPathComponent() ?? Settings.shared.saveDirectory
            panel.nameFieldStringValue = proposedURL?.lastPathComponent
                ?? recordingFilename(size: size)
            let qualityView = RecordingQualityView(quality: Settings.shared.recordingQuality, sourceSize: size)
            panel.accessoryView = qualityView
            savePanel = panel
            NSApp.activate(ignoringOtherApps: true)
            let response = panel.runModal()
            savePanel = nil
            guard !isTerminating, !Task.isCancelled else { return false }
            guard response == .OK, let destination = panel.url else { return false }
            proposedURL = destination
            let quality = qualityView.quality
            Settings.shared.recordingQuality = quality
            let task = Task {
                try await RecordingExport.save(source: source, to: destination, quality: quality,
                                               annotations: annotations)
            }
            exportTask = task
            let progress = RecordingExportPanel { [weak self] in self?.exportTask?.cancel() }
            exportPanel = progress
            progress.makeKeyAndOrderFront(nil)
            do {
                try await task.value
                closeExportPanel()
                Log.debug("Recording saved: \(destination.lastPathComponent), \(quality.title)", Log.output)
                return true
            } catch {
                closeExportPanel()
                guard !isTerminating, !Task.isCancelled else { return false }
                if error is CancellationError { return false }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "The recording could not be saved"
                alert.informativeText = error.localizedDescription
                    + "\n\nYour recording and annotations are still available. Retry or return to the editor."
                alert.addButton(withTitle: "Try Again")
                alert.addButton(withTitle: "Back to Editor")
                if alert.runModal() == .alertSecondButtonReturn { return false }
            }
        }
        return false
    }

    private func recordingFilename(size: CGSize) -> String {
        let screenshotName = OutputService.filename(size: size)
        let name = screenshotName.hasPrefix("Screenshot ")
            ? "Recording " + screenshotName.dropFirst("Screenshot ".count)
            : "Recording " + screenshotName
        return name + ".mp4"
    }

    private func shouldDiscard() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Discard this recording?"
        alert.informativeText = "The recording and its annotations will be removed."
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Discard Recording")
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func closeRecordingPanel() {
        recordingOutline?.close()
        recordingOutline = nil
        recordingPanel?.close()
        recordingPanel = nil
    }

    private func closeExportPanel() {
        exportPanel?.close()
        exportPanel = nil
        exportTask = nil
    }

    private func reset() {
        closeRecordingPanel()
        closeExportPanel()
        editor?.delegate = nil
        editor?.close()
        editor = nil
        session?.cleanUp()
        session = nil
        startTask = nil
        saveTask = nil
        phase = nil
    }

    /// Ask AppKit to delay termination until capture and export have released
    /// their files. Cancellation never commits a partially encoded destination.
    func prepareForTermination() async {
        isTerminating = true
        savePanel?.cancel(nil)
        startTask?.cancel()
        exportTask?.cancel()
        saveTask?.cancel()
        await startTask?.value
        if let session {
            await session.stop()
            _ = try? await session.waitUntilFinished()
        }
        await saveTask?.value
        reset()
    }
}
