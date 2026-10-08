import AppKit
import ImageIO

/// Frozen pixels and their mapping to editor points, independent of a monitor.
struct EditorImageSource {
    let image: CGImage
    let scale: CGFloat
    let size: CGSize

    init(image: CGImage, scale: CGFloat, size: CGSize? = nil) {
        self.image = image
        self.scale = scale
        self.size = size ?? CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }

    static func clipboard(_ image: CGImage, fitting available: CGSize) -> Self {
        let scale = max(1, CGFloat(image.width) / max(1, available.width),
                        CGFloat(image.height) / max(1, available.height))
        return Self(image: image, scale: scale)
    }

    var bounds: CGRect { CGRect(origin: .zero, size: size) }

    func color(at point: CGPoint) -> NSColor? {
        let x = Int((point.x * scale).rounded(.down))
        let y = Int((point.y * scale).rounded(.down))
        guard x >= 0, y >= 0, x < image.width, y < image.height,
              let single = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        return NSBitmapImageRep(cgImage: single).colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB)
    }
}

enum ClipboardImage {
    /// Read only explicit image representations. File URLs must never open files.
    static func read(from pasteboard: NSPasteboard = .general) -> CGImage? {
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            guard let data = pasteboard.data(forType: type),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            return image
        }
        return nil
    }
}
