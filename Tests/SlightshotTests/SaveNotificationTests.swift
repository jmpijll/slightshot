import AppKit
import Testing
import UserNotifications
@testable import Slightshot

@MainActor
struct SaveNotificationTests {
    @Test func attachmentIsAThumbnailCopyAndTheSavedFileStays() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SaveNotificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = try fixture(width: 3000, height: 1200)
        let saved = folder.appendingPathComponent("Screenshot.png")
        try #require(Renderer.encode(image, as: .png, quality: 1)).write(to: saved)
        let savedBytes = try Data(contentsOf: saved)

        let content = SaveNotification.content(savedFile: saved, image: image, copied: false)

        #expect(content.title == "Saved")
        #expect(content.body == "Screenshot.png")
        let attachment = try #require(content.attachments.first)
        defer { try? FileManager.default.removeItem(at: attachment.url) }
        #expect(try Data(contentsOf: saved) == savedBytes)
        #expect(attachment.url.standardizedFileURL != saved.standardizedFileURL)
        #expect(attachment.url.deletingLastPathComponent().standardizedFileURL
                == SaveNotification.attachmentDirectory.standardizedFileURL)
        let thumbnail = try #require(NSImage(contentsOf: attachment.url)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(thumbnail.width == SaveNotification.thumbnailMaxPixels)
        #expect(thumbnail.height == 256)
    }

    @Test func copyAfterSaveIsOneNotificationThatSaysSo() throws {
        let image = try fixture(width: 40, height: 20)
        let saved = URL(fileURLWithPath: "/tmp/Screenshot.png")
        let content = SaveNotification.content(savedFile: saved, image: image, copied: true)
        for attachment in content.attachments { try? FileManager.default.removeItem(at: attachment.url) }
        #expect(content.title == "Saved and copied to clipboard")
        #expect(content.body == "Screenshot.png")
    }

    @Test func saveSaveAsAndCopyAfterSaveEachPostExactlyOneNotification() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SaveNotificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let settings = Settings.shared
        let original = (settings.saveDirectory, settings.imageFormat, settings.showNotification, settings.copyAfterSave)
        let originalDeliver = SaveNotification.deliver
        var posted: [UNNotificationRequest] = []
        defer {
            (settings.saveDirectory, settings.imageFormat) = (original.0, original.1)
            (settings.showNotification, settings.copyAfterSave) = (original.2, original.3)
            SaveNotification.deliver = originalDeliver
            for attachment in posted.flatMap(\.content.attachments) {
                try? FileManager.default.removeItem(at: attachment.url)
            }
            try? FileManager.default.removeItem(at: folder)
        }
        settings.saveDirectory = folder
        settings.imageFormat = .png
        settings.showNotification = true
        settings.copyAfterSave = false
        SaveNotification.deliver = { posted.append($0) }
        let image = try fixture(width: 64, height: 32)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }

        let saved = try #require(OutputService.save(image))
        #expect(posted.map(\.content.title) == ["Saved"])

        let chosen = folder.appendingPathComponent("Chosen.png")
        #expect(OutputService.saveAs(image, chooseURL: { _ in chosen }) == chosen)
        #expect(posted.map(\.content.title) == ["Saved", "Saved"])
        #expect(posted.last?.content.body == "Chosen.png")

        settings.copyAfterSave = true
        let copied = folder.appendingPathComponent("Copied.png")
        #expect(OutputService.write(image, to: copied, pasteboard: board) == copied)
        #expect(posted.map(\.content.title) == ["Saved", "Saved", "Saved and copied to clipboard"])
        #expect(board.data(forType: .png) != nil)

        OutputService.copyToClipboard(image, to: board)
        #expect(posted.count == 3)
        for url in [saved, chosen, copied] { #expect(FileManager.default.fileExists(atPath: url.path)) }
    }

    private func fixture(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.systemTeal.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }
}
