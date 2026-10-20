import AppKit
import Testing
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

    private func fixture(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.systemTeal.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }
}
