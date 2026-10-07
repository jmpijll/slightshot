import AppKit
import CoreImage.CIFilterBuiltins

nonisolated enum RasterEffect {
    case blur, pixelate
}

/// Processes only the requested pixels. Reusing the Core Image context avoids
/// rebuilding its GPU resources for every pointer update.
enum RasterEffects {
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private static let imageContext = CIContext(options: [.workingColorSpace: colorSpace,
                                                         .cacheIntermediates: false])

    static func render(_ effect: RasterEffect, image: CGImage, pixels: CGRect, scale: CGFloat) -> CGImage? {
        switch effect {
        case .blur:
            let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            let sampleRect = pixels.insetBy(dx: -24 * scale, dy: -24 * scale).integral.intersection(bounds)
            guard let sample = image.cropping(to: sampleRect) else { return nil }
            let filter = CIFilter.gaussianBlur()
            filter.inputImage = CIImage(cgImage: sample).clampedToExtent()
            filter.radius = Float(8 * scale)
            let outputRect = CGRect(x: pixels.minX - sampleRect.minX,
                                    y: sampleRect.maxY - pixels.maxY,
                                    width: pixels.width, height: pixels.height)
            guard let output = filter.outputImage else { return nil }
            return imageContext.createCGImage(output, from: outputRect, format: .RGBA8, colorSpace: colorSpace)
        case .pixelate:
            guard let crop = image.cropping(to: pixels) else { return nil }
            return pixelate(crop, blockSize: max(1, Int((12 * scale).rounded())))
        }
    }

    /// Average premultiplied channels per block, including partial edge blocks.
    /// This also avoids interpolated or transparent edges in the exported image.
    private static func pixelate(_ image: CGImage, blockSize: Int) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        for top in stride(from: 0, to: height, by: blockSize) {
            for left in stride(from: 0, to: width, by: blockSize) {
                let bottom = min(top + blockSize, height), right = min(left + blockSize, width)
                var sums = [Int](repeating: 0, count: 4)
                for y in top..<bottom {
                    for x in left..<right {
                        let offset = (y * width + x) * 4
                        for channel in 0..<4 { sums[channel] += Int(bytes[offset + channel]) }
                    }
                }
                let count = (bottom - top) * (right - left)
                let average = sums.map { UInt8(($0 + count / 2) / count) }
                for y in top..<bottom {
                    for x in left..<right {
                        let offset = (y * width + x) * 4
                        for channel in 0..<4 { bytes[offset + channel] = average[channel] }
                    }
                }
            }
        }
        return context.makeImage()
    }
}
