import AppKit

/// Native window operations are kept at the edge of the editable capture session.
@MainActor
protocol OverlayPresentation {
    func show(_ views: [OverlayView], focused: OverlayView?)
    func focus(_ view: OverlayView)
    func hide()
    func close()
}

final class OverlayWindows: OverlayPresentation {
    private var windows: [OverlayWindow] = []
    private var didEscalateActivationPolicy = false

    func show(_ views: [OverlayView], focused: OverlayView?) {
        NSApp.activate(ignoringOtherApps: true)
        if windows.isEmpty {
            for view in views {
                let window = OverlayWindow(screen: view.display.screen)
                window.contentView = view
                windows.append(window)
            }
        }
        for window in windows { window.orderFrontRegardless() }
        if let focused { focus(focused) }
        NSCursor.crosshair.set()
        if !NSApp.isActive {
            didEscalateActivationPolicy = true
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            if let focused { focus(focused) }
        }
    }

    func focus(_ view: OverlayView) {
        guard let window = view.window else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    func hide() {
        for window in windows { window.orderOut(nil) }
        NSCursor.arrow.set()
    }

    func close() {
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        windows.removeAll()
        NSCursor.arrow.set()
        if didEscalateActivationPolicy {
            didEscalateActivationPolicy = false
            NSApp.setActivationPolicy(.accessory)
        }
        NSApp.hide(nil)
    }
}
