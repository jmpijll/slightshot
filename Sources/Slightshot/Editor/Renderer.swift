import AppKit

enum Renderer {
    /// Flattens the frozen screenshot plus its annotations into a single image.
    ///
    /// The bitmap context is built in *pixels*, then transformed so that drawing
    /// happens in the same flipped, top-left-origin point space the overlay view
    /// uses. That way `Annotation.draw()` is shared verbatim between the live
    /// canvas and the export, and there is no second code path to keep in sync.
    static func flatten(display: CapturedDisplay, selection: CGRect, annotations: [Annotation]) -> CGImage? {
        let rect = selection.pixelAligned
        guard let base = display.crop(to: rect) else { return nil }

        let pixelWidth = base.width
        let pixelHeight = base.height
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        guard let context = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(base, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        if !annotations.isEmpty {
            context.saveGState()
            context.translateBy(x: 0, y: CGFloat(pixelHeight))
            context.scaleBy(x: display.scale, y: -display.scale)
            context.translateBy(x: -rect.minX, y: -rect.minY)

            let graphics = NSGraphicsContext(cgContext: context, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            for annotation in annotations { annotation.draw() }
            NSGraphicsContext.restoreGraphicsState()

            context.restoreGState()
        }

        return context.makeImage()
    }

    /// Encodes to the user's chosen container format.
    static func encode(_ image: CGImage, as format: ImageFormat, quality: Double) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        switch format {
        case .png:
            return rep.representation(using: .png, properties: [:])
        case .jpeg:
            return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        case .tiff:
            let lzw = NSBitmapImageRep.TIFFCompression.lzw.rawValue
            return rep.representation(using: .tiff, properties: [.compressionMethod: lzw])
        }
    }
}
