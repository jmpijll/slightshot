import AppKit

/// Owns a capture session: freezes every display, puts an `OverlayView` on each
/// one, and routes whatever the user chooses to `OutputService`.
final class OverlayCoordinator: OverlayViewDelegate {
    static let shared = OverlayCoordinator()

    private var windows: [OverlayWindow] = []
    private var views: [OverlayView] = []
    private var isCapturing = false
    /// Set when we had to escalate to `.regular` to win activation.
    private var didEscalateActivationPolicy = false

    private init() {}

    var isActive: Bool { !windows.isEmpty }

    // MARK: - Region capture

    func beginRegionCapture() {
        guard !isActive, !isCapturing else {
            Log.debug("Region capture ignored (active: \(isActive), capturing: \(isCapturing))", Log.overlay)
            return
        }
        isCapturing = true
        Log.debug("Region capture starting", Log.overlay)
        Task {
            defer { isCapturing = false }
            do {
                let displays = try await ScreenCapture.captureAllDisplays()
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

    private func present(_ displays: [CapturedDisplay]) {
        let mouse = NSEvent.mouseLocation

        // Activate *before* ordering windows in. A menu-bar-only app triggered by
        // a global hotkey is not frontmost, and a window that is merely ordered
        // front in an inactive app receives mouse events but no key events — the
        // exact failure mode where Esc and ⌘C silently do nothing.
        activateForCapture()

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
        let index = displays.firstIndex { $0.frame.contains(mouse) } ?? 0
        if windows.indices.contains(index) {
            windows[index].makeKeyAndOrderFront(nil)
            windows[index].makeFirstResponder(views[index])
        }
        NSCursor.crosshair.set()

        Log.debug("Overlay presented on \(windows.count) window(s); "
                  + "active: \(NSApp.isActive), key: \(windows[safe: index]?.isKeyWindow ?? false)", Log.overlay)

        // If cooperative activation refused us, escalate: a .regular app is
        // always allowed to come forward. Restored on dismiss.
        if !NSApp.isActive {
            Log.debug("Activation refused; escalating to .regular", Log.overlay)
            didEscalateActivationPolicy = true
            NSApp.setActivationPolicy(.regular)
            activateForCapture()
            if windows.indices.contains(index) {
                windows[index].makeKeyAndOrderFront(nil)
                windows[index].makeFirstResponder(views[index])
            }
        }
    }

    private func activateForCapture() {
        NSApp.activate(ignoringOtherApps: true)
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
        if didEscalateActivationPolicy {
            didEscalateActivationPolicy = false
            NSApp.setActivationPolicy(.accessory)
        }
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
