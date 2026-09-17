import AppKit

/// Owns a capture session: freezes every display, puts an `OverlayView` on each
/// one, and routes whatever the user chooses to `OutputService`.
final class OverlayCoordinator: OverlayViewDelegate {
    static let shared = OverlayCoordinator()

    private var windows: [OverlayWindow] = []
    private var views: [OverlayView] = []
    private var isCapturing = false

    private init() {}

    var isActive: Bool { !windows.isEmpty }

    // MARK: - Region capture

    func beginRegionCapture() {
        guard !isActive, !isCapturing else { return }
        isCapturing = true
        Task {
            defer { isCapturing = false }
            do {
                let displays = try await ScreenCapture.captureAllDisplays()
                present(displays)
            } catch CaptureError.permissionDenied {
                ScreenRecordingPermission.request()
                ScreenRecordingPermission.presentDeniedAlert()
            } catch {
                OutputService.presentError(error.localizedDescription)
            }
        }
    }

    private func present(_ displays: [CapturedDisplay]) {
        let mouse = NSEvent.mouseLocation

        for captured in displays {
            let window = OverlayWindow(screen: captured.screen)
            let view = OverlayView(display: captured)
            view.delegate = self
            window.contentView = view
            windows.append(window)
            views.append(view)

            window.orderFrontRegardless()
            view.prepare(isUnderMouse: captured.frame.contains(mouse))
        }

        // Key focus goes to the display the pointer is on, so ⌘C/⌘S land there.
        NSApp.activate(ignoringOtherApps: true)
        if let index = displays.firstIndex(where: { $0.frame.contains(mouse) }) {
            windows[index].makeKeyAndOrderFront(nil)
            windows[index].makeFirstResponder(views[index])
        } else {
            windows.first?.makeKeyAndOrderFront(nil)
        }
        NSCursor.crosshair.set()
    }

    func dismiss() {
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        windows.removeAll()
        views.removeAll()
        NSCursor.arrow.set()
        NSApp.hide(nil)
    }

    // MARK: - Whole-screen shortcuts

    func captureFullScreen(_ action: CaptureAction) {
        guard !isCapturing else { return }
        isCapturing = true
        Task {
            defer { isCapturing = false }
            do {
                let display = try await ScreenCapture.captureActiveDisplay()
                deliver(action, image: display.image)
            } catch CaptureError.permissionDenied {
                ScreenRecordingPermission.request()
                ScreenRecordingPermission.presentDeniedAlert()
            } catch {
                OutputService.presentError(error.localizedDescription)
            }
        }
    }

    // MARK: - OverlayViewDelegate

    func overlayDidCancel(_ view: OverlayView) {
        dismiss()
    }

    func overlayDidTakeOver(_ view: OverlayView) {
        for other in views where other !== view { other.relinquish() }
        if let window = view.window, !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
        }
    }

    func overlay(_ view: OverlayView, didComplete action: CaptureAction, image: CGImage) {
        // Tear the overlay down first: panels and print sheets must not have to
        // fight a shielding-level window for focus.
        dismiss()
        deliver(action, image: image)
    }

    private func deliver(_ action: CaptureAction, image: CGImage) {
        switch action {
        case .copy:
            OutputService.copyToClipboard(image)
            OutputService.playShutter()
        case .save:
            OutputService.save(image)
            OutputService.playShutter()
        case .saveAs:
            OutputService.saveAs(image)
        case .print:
            OutputService.print(image)
        }
    }
}
