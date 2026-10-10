import AppKit

/// Preparation uses the screenshot renderer on the main actor. Export receives
/// immutable pixels and Core Graphics geometry, so no AppKit drawing runs on its
/// worker. Raster effects are evaluated again on each current video frame.
enum VideoFrameRenderer {
    nonisolated struct PreparedAnnotation: Sendable {
        let start: TimeInterval
        let end: TimeInterval
        let rect: CGRect
        let overlay: CGImage?
        let effect: RasterEffect?
        let rasterScale: CGFloat

        func isActive(at time: TimeInterval) -> Bool { time >= start && time < end }
    }

    static func render(image: CGImage, at time: TimeInterval, annotations: [VideoAnnotation],
                       scale: CGFloat = 1) -> CGImage? {
        Renderer.flatten(image: image, scale: scale,
                         selection: CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale,
                                           height: CGFloat(image.height) / scale),
                         annotations: VideoAnnotation.active(in: annotations, at: time))
    }

    static func prepare(_ annotations: [VideoAnnotation], size: CGSize,
                        duration: TimeInterval) throws -> [PreparedAnnotation] {
        guard !annotations.isEmpty else { return [] }
        let bounds = CGRect(origin: .zero, size: size)
        guard let transparentContext = makeContext(size: size),
              let transparent = transparentContext.makeImage() else {
            throw RecordingError.failed("The annotation layer could not be prepared.")
        }
        return try annotations.compactMap { value in
            let value = value.clamped(to: duration)
            guard value.duration > 0 else { return nil }
            if let effect = value.annotation.rasterEffect {
                guard !effect.rect.isEmpty else { return nil }
                let rect = effect.rect.integral.intersection(bounds)
                guard !rect.isNull, !rect.isEmpty else { return nil }
                return PreparedAnnotation(start: value.start, end: value.end, rect: rect,
                                          overlay: nil, effect: effect.effect,
                                          rasterScale: value.annotation.effectiveRasterScale)
            }
            let rect = value.annotation.dirtyBounds.integral.intersection(bounds)
            guard !rect.isNull, !rect.isEmpty else { return nil }
            guard let overlay = Renderer.flatten(image: transparent, scale: 1,
                                                 selection: rect, annotations: [value.annotation]) else {
                throw RecordingError.failed("A video annotation could not be drawn.")
            }
            return PreparedAnnotation(start: value.start, end: value.end, rect: rect,
                                      overlay: overlay, effect: nil, rasterScale: 1)
        }
    }

    nonisolated static func makeContext(size: CGSize) -> CGContext? {
        CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    /// The same ordering as Renderer.flatten: a blur after a drawn mark also
    /// blurs that mark. The reusable context is reset to the current frame first.
    nonisolated static func render(
        image: CGImage, at time: TimeInterval, prepared: [PreparedAnnotation], context: CGContext
    ) throws -> CGImage {
        let bounds = CGRect(x: 0, y: 0, width: context.width, height: context.height)
        context.saveGState()
        context.setBlendMode(.copy)
        context.draw(image, in: bounds)
        context.restoreGState()
        for value in prepared where value.isActive(at: time) {
            let destination = CGRect(x: value.rect.minX, y: CGFloat(context.height) - value.rect.maxY,
                                     width: value.rect.width, height: value.rect.height)
            if let effect = value.effect {
                guard let current = context.makeImage(),
                      let patch = RasterEffects.render(effect, image: current, pixels: value.rect,
                                                       scale: value.rasterScale) else {
                    throw RecordingError.failed("A video privacy effect could not be applied.")
                }
                context.saveGState()
                context.setBlendMode(.copy)
                context.draw(patch, in: destination)
                context.restoreGState()
            } else if let overlay = value.overlay {
                context.draw(overlay, in: destination)
            }
        }
        guard let result = context.makeImage() else {
            throw RecordingError.failed("The annotated video frame could not be rendered.")
        }
        return result
    }
}
