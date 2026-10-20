import AppKit
import UniformTypeIdentifiers
import UserNotifications

/// Everything that happens *after* a capture: clipboard, disk, printer.
enum OutputService {
    /// Returns false when the user cancels or an output operation fails.
    static func perform(_ action: CaptureAction, image: CGImage) -> Bool {
        switch action {
        case .copy:
            copyToClipboard(image)
            playShutter()
            return true
        case .save:
            guard save(image) != nil else { return false }
            playShutter()
            return true
        case .saveAs:
            return saveAs(image) != nil
        case .print:
            return print(image)
        }
    }

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
        if settings.showNotification {
            SaveNotification.post(savedFile: url, image: image, copied: settings.copyAfterSave)
        }
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

    @discardableResult
    static func print(_ image: CGImage) -> Bool {
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
        return operation.run()
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

/// The "Show a notification after saving" setting.
enum SaveNotification {
    /// macOS moves an attachment file into its own store when the notification is added,
    /// so the notification carries a thumbnail copy and never the saved file itself.
    static let attachmentDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SaveNotificationAttachments", isDirectory: true)
    static let thumbnailMaxPixels = 640

    /// Notification Center needs an app bundle; an unbundled `swift run` binary has none.
    private static var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    static var settingsURL: URL {
        let id = Bundle.main.bundleIdentifier.map { "?id=\($0)" } ?? ""
        return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension\(id)")!
    }

    static func post(savedFile: URL, image: CGImage, copied: Bool) {
        guard let center else { return }
        let content = content(savedFile: savedFile, image: image, copied: copied)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            do {
                try await center.add(request)
            } catch {
                Log.output.error("Save notification failed: \(error.localizedDescription, privacy: .public)")
            }
            // Normally already moved into the notification store; this removes a copy it rejected.
            for attachment in content.attachments { try? FileManager.default.removeItem(at: attachment.url) }
        }
    }

    static func content(savedFile: URL, image: CGImage, copied: Bool) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = copied ? "Saved and copied to clipboard" : "Saved"
        content.body = savedFile.lastPathComponent
        content.sound = nil
        if let attachment = thumbnailAttachment(of: image) { content.attachments = [attachment] }
        return content
    }

    /// Asks only while undecided; afterwards macOS answers with the stored choice.
    static func requestAuthorization() async -> Bool {
        guard let center else { return false }
        do {
            return try await center.requestAuthorization(options: [.alert])
        } catch {
            Log.app.error("Notification authorisation failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    static func isDenied() async -> Bool {
        guard let center else { return false }
        return await center.notificationSettings().authorizationStatus == .denied
    }

    private static func thumbnailAttachment(of image: CGImage) -> UNNotificationAttachment? {
        let scale = min(1, CGFloat(thumbnailMaxPixels) / CGFloat(max(image.width, image.height)))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let thumbnail = context.makeImage(),
              let png = Renderer.encode(thumbnail, as: .png, quality: 1) else { return nil }

        let url = attachmentDirectory.appendingPathComponent(UUID().uuidString + ".png")
        do {
            try FileManager.default.createDirectory(at: attachmentDirectory, withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
            return try UNNotificationAttachment(identifier: url.lastPathComponent, url: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            Log.output.error("Save notification thumbnail failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
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
