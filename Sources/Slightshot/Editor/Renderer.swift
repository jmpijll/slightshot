import AppKit

enum Renderer {
    /// Flattens the frozen screenshot plus its annotations into a single image.
    ///
    /// The bitmap context is built in *pixels*, then transformed so that drawing
    /// happens in the same flipped, top-left-origin point space the overlay view
    /// uses. That way `Annotation.draw()` is shared verbatim between the live
    /// canvas and the export, and there is no second code path to keep in sync.
    static func flatten(display: CapturedDisplay, selection: CGRect, annotations: [Annotation]) -> CGImage? {
        flatten(image: display.image, scale: display.scale, selection: selection.pixelAligned, annotations: annotations)
    }

    static func flatten(image: CGImage, scale: CGFloat, selection: CGRect, annotations: [Annotation]) -> CGImage? {
        let pixels = selectionPixels(image: image, scale: scale, selection: selection)
        let rect = CGRect(x: pixels.minX / scale, y: pixels.minY / scale,
                          width: pixels.width / scale, height: pixels.height / scale)
        guard !pixels.isNull, pixels.width >= 1, pixels.height >= 1,
              let base = image.cropping(to: pixels) else { return nil }

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

        for annotation in annotations {
            if annotation.rasterEffect != nil {
                guard let source = context.makeImage() else { return nil }
                if let patch = effectPatch(annotation, source: source, selection: rect, scale: scale) {
                    let destination = CGRect(x: patch.pixels.minX, y: CGFloat(pixelHeight) - patch.pixels.maxY,
                                             width: patch.pixels.width, height: patch.pixels.height)
                    context.saveGState()
                    context.setBlendMode(.copy)
                    context.draw(patch.image, in: destination)
                    context.restoreGState()
                } else if let effect = annotation.rasterEffect,
                          effect.rect.intersection(rect).width >= 1, effect.rect.intersection(rect).height >= 1 {
                    return nil // Never export the unmodified pixels if an effect fails.
                }
                continue
            }
            context.saveGState()
            context.translateBy(x: 0, y: CGFloat(pixelHeight))
            context.scaleBy(x: scale, y: -scale)
            context.translateBy(x: -rect.minX, y: -rect.minY)

            let graphics = NSGraphicsContext(cgContext: context, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            annotation.draw()
            NSGraphicsContext.restoreGraphicsState()

            context.restoreGState()
        }

        return context.makeImage()
    }

    /// Crops cover source pixel boundaries; marks use that same integer origin.
    static func alignedSelectionRect(image: CGImage, scale: CGFloat, selection: CGRect) -> CGRect {
        let pixels = selectionPixels(image: image, scale: scale, selection: selection)
        guard !pixels.isNull else { return .zero }
        return CGRect(x: pixels.minX / scale, y: pixels.minY / scale,
                      width: pixels.width / scale, height: pixels.height / scale)
    }

    private static func selectionPixels(image: CGImage, scale: CGFloat, selection: CGRect) -> CGRect {
        // Division by a fractional fit scale can return an exact pixel boundary
        // a few floating-point ulps away from its integer coordinate.
        func snap(_ value: CGFloat) -> CGFloat {
            abs(value - value.rounded()) < 0.00000001 ? value.rounded() : value
        }
        let left = snap(selection.minX * scale).rounded(.down)
        let top = snap(selection.minY * scale).rounded(.down)
        let right = snap(selection.maxX * scale).rounded(.up)
        let bottom = snap(selection.maxY * scale).rounded(.up)
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    /// Both the live preview and export use this exact raster patch.
    static func effectPatch(_ annotation: Annotation, source: CGImage, selection: CGRect,
                            scale: CGFloat) -> (image: CGImage, pixels: CGRect)? {
        guard let effect = annotation.rasterEffect, !effect.rect.isEmpty else { return nil }
        let local = CGRect(x: effect.rect.minX - selection.minX, y: effect.rect.minY - selection.minY,
                           width: effect.rect.width, height: effect.rect.height)
        let pixels = selectionPixels(image: source, scale: scale, selection: local)
        guard !pixels.isNull, pixels.width >= 1, pixels.height >= 1,
              let image = RasterEffects.render(effect.effect, image: source, pixels: pixels, scale: scale)
        else { return nil }
        return (image, pixels)
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
