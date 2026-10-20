import AppKit

/// Owns a capture session: freezes every display, puts an `OverlayView` on each
/// one, and routes whatever the user chooses to `OutputService`.
final class OverlayCoordinator: OverlayViewDelegate {
    static let shared = OverlayCoordinator()

    private var views: [OverlayView] = []
    private var isCapturing = false
    private var isDelivering = false
    private let presentation: any OverlayPresentation
    private let clipboardPresentation: any OverlayPresentation
    private var currentPresentation: any OverlayPresentation {
        views.first?.capturedDisplay == nil ? clipboardPresentation : presentation
    }
    private let output: @MainActor (CaptureAction, CGImage) -> Bool
    private let record: @MainActor (CapturedDisplay, CGRect) -> Void
    private let captureAll: @MainActor () async throws -> [CapturedDisplay]
    private let captureActive: @MainActor () async throws -> CapturedDisplay

    init(presentation: any OverlayPresentation = OverlayWindows(),
         clipboardPresentation: any OverlayPresentation = ClipboardEditorWindows(),
         output: @escaping @MainActor (CaptureAction, CGImage) -> Bool = OutputService.perform,
         record: @escaping @MainActor (CapturedDisplay, CGRect) -> Void = {
             RecordingCoordinator.shared.begin(display: $0, selection: $1)
         },
         captureAll: @escaping @MainActor () async throws -> [CapturedDisplay] = ScreenCapture.captureAllDisplays,
         captureActive: @escaping @MainActor () async throws -> CapturedDisplay = ScreenCapture.captureActiveDisplay) {
        self.presentation = presentation
        self.clipboardPresentation = clipboardPresentation
        self.output = output
        self.record = record
        self.captureAll = captureAll
        self.captureActive = captureActive
    }

    var isActive: Bool { !views.isEmpty }
    var isBusy: Bool { isActive || isCapturing || isDelivering }

    // MARK: - Region capture

    func beginRegionCapture() {
        guard !isBusy, !RecordingCoordinator.shared.isBusy else {
            Log.debug("Region capture ignored (active: \(isActive), capturing: \(isCapturing))", Log.overlay)
            return
        }
        isCapturing = true
        Log.debug("Region capture starting", Log.overlay)
        Task {
            defer { isCapturing = false }
            do {
                let displays = try await captureAll()
                Log.debug("Captured \(displays.count) display(s)", Log.overlay)
                present(displays)
            } catch CaptureError.permissionDenied {
                Log.debug("Screen Recording permission denied", Log.overlay)
                ScreenRecordingPermission.request()
                ScreenRecordingPermission.presentDeniedAlert()
            } catch {
                Log.debug("Region capture failed: \(error)", Log.overlay)
                OutputService.presentError(error.localizedDescription)
            }
        }
    }

    func present(_ displays: [CapturedDisplay]) {
        guard !isActive, !isDelivering else { return }
        let mouse = NSEvent.mouseLocation
        views = displays.map { display in
            let view = OverlayView(display: display)
            view.delegate = self
            return view
        }
        let index = displays.firstIndex { $0.frame.contains(mouse) } ?? 0
        presentation.show(views, focused: views[safe: index])
        for view in views { view.prepare(isUnderMouse: view.capturedDisplay?.frame.contains(mouse) == true) }
    }

    func dismiss() {
        guard !isDelivering else { return }
        currentPresentation.close()
        views.removeAll()
    }

    // MARK: - Clipboard editor

    func editImageFromClipboard() {
        guard !isBusy, !RecordingCoordinator.shared.isBusy else { return }
        guard let image = ClipboardImage.read() else {
            OutputService.presentError("The clipboard does not contain an image. Copy an image and try again.")
            return
        }
        presentClipboardImage(image)
    }

    func presentClipboardImage(_ image: CGImage) {
        guard !isBusy, !RecordingCoordinator.shared.isBusy else { return }
        let available = ClipboardEditorWindow.availableImageSize
        let source = EditorImageSource.clipboard(image, fitting: available)
        let view = OverlayView(source: source)
        view.delegate = self
        views = [view]
        clipboardPresentation.show(views, focused: view)
    }

    // MARK: - Whole-screen shortcuts

    func captureFullScreen(_ action: CaptureAction) {
        guard !isBusy, !RecordingCoordinator.shared.isBusy else { return }
        isCapturing = true
        Task {
            defer { isCapturing = false }
            do {
                let display = try await captureActive()
                deliver(action, image: display.image)
            } catch CaptureError.permissionDenied {
                ScreenRecordingPermission.request()
                ScreenRecordingPermission.presentDeniedAlert()
            } catch {
                OutputService.presentError(error.localizedDescription)
            }
        }
    }

    // MARK: - Quitting

    /// Annotations exist only in the open editor until they are copied or saved.
    var unsavedWork: UnsavedWork? {
        views.contains { !$0.annotations.isEmpty } ? .annotations : nil
    }

    /// The capture overlay floats above alerts, so it steps aside while one is open.
    func withOverlayHidden<T>(_ body: () -> T) -> T {
        guard isActive else { return body() }
        currentPresentation.hide()
        defer { if isActive { currentPresentation.show(views, focused: annotatedView) } }
        return body()
    }

    /// Copies the annotated capture with the toolbar's own Copy action.
    func copyAnnotatedCapture() -> Bool {
        annotatedView?.toolbarDidRequest(.copy)
        return !isActive
    }

    private var annotatedView: OverlayView? { views.first { !$0.annotations.isEmpty } }

    // MARK: - OverlayViewDelegate

    func overlayDidCancel(_ view: OverlayView) {
        dismiss()
    }

    func overlayDidTakeOver(_ view: OverlayView) {
        guard !isDelivering, views.contains(where: { $0 === view }) else { return }
        for other in views where other !== view { other.relinquish() }
        currentPresentation.focus(view)
    }

    func overlay(_ view: OverlayView, didComplete action: CaptureAction, image: CGImage) {
        guard !isDelivering, views.contains(where: { $0 === view }) else { return }
        isDelivering = true
        // Hide the native windows for modal focus while retaining the frozen
        // pixels and the real editor instances until output succeeds.
        currentPresentation.hide()
        let succeeded = output(action, image)
        isDelivering = false
        if succeeded { dismiss() } else { currentPresentation.show(views, focused: view) }
    }

    func overlay(_ view: OverlayView, didRequestRecording selection: CGRect) {
        guard !isDelivering, views.contains(where: { $0 === view }) else { return }
        guard let display = view.capturedDisplay else { return }
        dismiss()
        record(display, selection)
    }

    private func deliver(_ action: CaptureAction, image: CGImage) {
        _ = output(action, image)
    }
}
