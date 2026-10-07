import AppKit
import UniformTypeIdentifiers

/// Selection → live recording → Stop → save-time quality. Keeping the frozen
/// screenshot overlay out of this lifecycle ensures the recorded screen is live.
final class RecordingCoordinator {
    static let shared = RecordingCoordinator()
    private enum Phase { case starting, recording, stopping, saving }
    private var phase: Phase?
    private var session: ScreenRecordingSession?
    private var recordingPanel: RecordingPanel?
    private var recordingOutline: RecordingOutlinePanel?
    private var savePanel: NSSavePanel?
    private var exportPanel: RecordingExportPanel?
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
                await self.chooseDestination(source: source, size: session.size)
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

    private func chooseDestination(source: URL, size: CGSize) async {
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
            guard !isTerminating, !Task.isCancelled else { return }
            guard response == .OK, let destination = panel.url else {
                if shouldDiscard() { return }
                continue
            }
            proposedURL = destination
            let quality = qualityView.quality
            Settings.shared.recordingQuality = quality
            let task = Task { try await RecordingExport.save(source: source, to: destination, quality: quality) }
            exportTask = task
            let progress = RecordingExportPanel { [weak self] in self?.exportTask?.cancel() }
            exportPanel = progress
            progress.makeKeyAndOrderFront(nil)
            do {
                try await task.value
                closeExportPanel()
                Log.debug("Recording saved: \(destination.lastPathComponent), \(quality.title)", Log.output)
                return
            } catch {
                closeExportPanel()
                guard !isTerminating, !Task.isCancelled else { return }
                if error is CancellationError { continue }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "The recording could not be saved"
                alert.informativeText = error.localizedDescription
                    + "\n\nYour recording is still available. Choose another location or quality and try again."
                alert.addButton(withTitle: "Try Again")
                alert.addButton(withTitle: "Discard Recording")
                if alert.runModal() == .alertSecondButtonReturn { return }
            }
        }
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
        alert.messageText = "Keep this recording?"
        alert.informativeText = "Choose a location to save it, or discard the recording."
        alert.addButton(withTitle: "Keep Recording")
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
