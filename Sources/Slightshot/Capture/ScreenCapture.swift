import AppKit
import ScreenCaptureKit

/// One display's frozen pixels plus everything needed to map between the
/// screen's point coordinates and the image's pixel coordinates.
struct CapturedDisplay {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    let image: CGImage
    /// Pixels per point for this display.
    let scale: CGFloat

    /// The display's frame in Cocoa global coordinates (origin bottom-left).
    var frame: CGRect { screen.frame }

    /// Converts a rect in top-left-origin view points to image pixels.
    func pixelRect(for rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * scale, y: rect.minY * scale,
               width: rect.width * scale, height: rect.height * scale).pixelAligned
    }

    /// Crops the frozen screenshot to a rect given in top-left-origin view points.
    func crop(to rect: CGRect) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let pixels = pixelRect(for: rect).clamped(to: bounds)
        guard pixels.width >= 1, pixels.height >= 1 else { return nil }
        return image.cropping(to: pixels)
    }

    /// The sRGB color of the pixel under a point in top-left-origin view points.
    func color(at point: CGPoint) -> NSColor? {
        let x = Int((point.x * scale).rounded(.down))
        let y = Int((point.y * scale).rounded(.down))
        guard x >= 0, y >= 0, x < image.width, y < image.height,
              let single = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))
        else { return nil }
        return NSBitmapImageRep(cgImage: single).colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB)
    }
}

nonisolated enum CaptureError: LocalizedError {
    case permissionDenied
    case noDisplays
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Slightshot needs Screen Recording permission to take screenshots."
        case .noDisplays:
            "No displays were available to capture."
        case .failed(let reason):
            "The screen could not be captured: \(reason)"
        }
    }
}

enum ScreenCapture {
    /// Captures every active display at native resolution, in parallel.
    static func captureAllDisplays() async throws -> [CapturedDisplay] {
        guard ScreenRecordingPermission.isGranted else { throw CaptureError.permissionDenied }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.failed(error.localizedDescription)
        }
        guard !content.displays.isEmpty else { throw CaptureError.noDisplays }

        // Never capture our own overlay or menu-bar windows.
        let ownBundleID = Bundle.main.bundleIdentifier
        let ownApps = content.applications.filter { $0.bundleIdentifier == ownBundleID }
        let includeCursor = Settings.shared.captureCursor

        // Captured serially: a screenshot is a few milliseconds and everything
        // here (NSScreen, SCDisplay, CGImage) is main-actor bound anyway.
        var results: [CapturedDisplay] = []
        for display in content.displays {
            guard let screen = NSScreen.screen(for: display.displayID) else { continue }
            let scale = Settings.shared.retinaScale ? screen.backingScaleFactor : 1

            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int((CGFloat(display.width) * scale).rounded())
            config.height = Int((CGFloat(display.height) * scale).rounded())
            config.showsCursor = includeCursor
            config.captureResolution = .best
            config.scalesToFit = false
            config.colorSpaceName = CGColorSpace.sRGB
            config.ignoreShadowsDisplay = true

            do {
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config
                )
                results.append(CapturedDisplay(screen: screen, displayID: display.displayID,
                                               image: image, scale: scale))
            } catch {
                let reason = error.localizedDescription
                Log.capture.error("Display \(display.displayID) failed: \(reason, privacy: .public)")
            }
        }

        guard !results.isEmpty else { throw CaptureError.noDisplays }
        return results
    }

    /// Captures only the display currently under the mouse pointer.
    ///
    /// Deliberately not `captureAllDisplays().first(where:)` — on a multi-display
    /// desk that grabs several full-resolution screenshots and discards all but
    /// one, which is both slow and a lot of memory for a ⌘⇧8.
    static func captureActiveDisplay() async throws -> CapturedDisplay {
        guard ScreenRecordingPermission.isGranted else { throw CaptureError.permissionDenied }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.failed(error.localizedDescription)
        }

        let mouse = NSEvent.mouseLocation
        let target = content.displays.first {
            NSScreen.screen(for: $0.displayID)?.frame.contains(mouse) ?? false
        } ?? content.displays.first

        guard let display = target, let screen = NSScreen.screen(for: display.displayID) else {
            throw CaptureError.noDisplays
        }

        let ownBundleID = Bundle.main.bundleIdentifier
        let ownApps = content.applications.filter { $0.bundleIdentifier == ownBundleID }
        let scale = Settings.shared.retinaScale ? screen.backingScaleFactor : 1

        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int((CGFloat(display.width) * scale).rounded())
        config.height = Int((CGFloat(display.height) * scale).rounded())
        config.showsCursor = Settings.shared.captureCursor
        config.captureResolution = .best
        config.scalesToFit = false
        config.colorSpaceName = CGColorSpace.sRGB
        config.ignoreShadowsDisplay = true

        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return CapturedDisplay(screen: screen, displayID: display.displayID, image: image, scale: scale)
        } catch {
            throw CaptureError.failed(error.localizedDescription)
        }
    }
}

extension NSScreen {
    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        screens.first { $0.displayID == displayID }
    }

    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }
}
