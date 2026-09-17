import AppKit
import UniformTypeIdentifiers
import UserNotifications

/// Everything that happens *after* a capture: clipboard, disk, printer.
enum OutputService {
    // MARK: - Clipboard

    static func copyToClipboard(_ image: CGImage) {
        let rep = NSBitmapImageRep(cgImage: image)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let item = NSPasteboardItem()
        if let png = rep.representation(using: .png, properties: [:]) {
            item.setData(png, forType: .png)
        }
        if let tiff = rep.representation(using: .tiff, properties: [:]) {
            item.setData(tiff, forType: .tiff)
        }
        pasteboard.writeObjects([item])
        feedback(title: "Copied to clipboard")
    }

    static func copyToClipboard(text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Saving

    /// Writes straight to the configured folder without prompting.
    @discardableResult
    static func save(_ image: CGImage) -> URL? {
        let settings = Settings.shared
        let format = settings.imageFormat
        guard let data = Renderer.encode(image, as: format, quality: settings.jpegQuality) else {
            presentError("Slightshot could not encode the image.")
            return nil
        }

        let directory = settings.saveDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            presentError("Could not create \(directory.path): \(error.localizedDescription)")
            return nil
        }

        let url = uniqueURL(in: directory, base: filename(size: CGSize(width: image.width, height: image.height)),
                            ext: format.fileExtension)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            presentError("Could not save to \(url.path): \(error.localizedDescription)")
            return nil
        }

        if settings.copyAfterSave { copyToClipboard(image) }
        feedback(title: "Saved", body: url.lastPathComponent, fileURL: url)
        return url
    }

    /// Shows a standard save panel, starting in the configured folder.
    @discardableResult
    static func saveAs(_ image: CGImage) -> URL? {
        let settings = Settings.shared
        let format = settings.imageFormat

        let panel = NSSavePanel()
        panel.directoryURL = settings.saveDirectory
        panel.nameFieldStringValue = filename(size: CGSize(width: image.width, height: image.height))
            + "." + format.fileExtension
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.level = .popUpMenu   // above the capture overlay

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url,
              let data = Renderer.encode(image, as: format, quality: settings.jpegQuality)
        else { return nil }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            presentError("Could not save to \(url.path): \(error.localizedDescription)")
            return nil
        }
        if settings.copyAfterSave { copyToClipboard(image) }
        return url
    }

    // MARK: - Printing

    static func print(_ image: CGImage) {
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        let view = NSImageView(frame: NSRect(origin: .zero, size: nsImage.size))
        view.image = nsImage
        view.imageScaling = .scaleProportionallyUpOrDown

        let info = NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true

        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        NSApp.activate(ignoringOtherApps: true)
        operation.run()
    }

    // MARK: - Naming

    static func filename(size: CGSize) -> String {
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH.mm.ss"

        var name = Settings.shared.filenameTemplate
        if name.trimmingCharacters(in: .whitespaces).isEmpty { name = "Screenshot {date} at {time}" }
        let replacements = [
            "{date}": dateFormatter.string(from: now),
            "{time}": timeFormatter.string(from: now),
            "{timestamp}": String(Int(now.timeIntervalSince1970)),
            "{width}": String(Int(size.width)),
            "{height}": String(Int(size.height)),
        ]
        for (token, value) in replacements { name = name.replacingOccurrences(of: token, with: value) }
        return name.replacingOccurrences(of: "/", with: "-")
    }

    private static func uniqueURL(in directory: URL, base: String, ext: String) -> URL {
        var candidate = directory.appendingPathComponent("\(base).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) (\(counter)).\(ext)")
            counter += 1
        }
        return candidate
    }

    // MARK: - Feedback

    static func playShutter() {
        guard Settings.shared.playSound else { return }
        let candidates = [
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif",
            "/System/Library/Sounds/Tink.aiff",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            NSSound(contentsOfFile: path, byReference: true)?.play()
            return
        }
    }

    private static func feedback(title: String, body: String? = nil, fileURL: URL? = nil) {
        guard Settings.shared.showNotification else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        if let body { content.body = body }
        content.sound = nil
        if let fileURL,
           let attachment = try? UNNotificationAttachment(identifier: fileURL.lastPathComponent, url: fileURL) {
            content.attachments = [attachment]
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func presentError(_ message: String) {
        Log.output.error("\(message, privacy: .public)")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Slightshot"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

extension ImageFormat {
    var contentType: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .tiff: .tiff
        }
    }
}
