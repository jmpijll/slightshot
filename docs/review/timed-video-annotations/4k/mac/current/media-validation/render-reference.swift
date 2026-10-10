import AppKit
import ImageIO

struct CapturedDisplay {
    let image: CGImage
    let scale: CGFloat
}
enum ImageFormat { case png, jpeg, tiff }

@main
@MainActor
struct ReviewReference {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let source = try load(directory.appendingPathComponent("source-02.png"))
        let fit: CGFloat = 928.0 / 3840.0
        let rects = [CGRect(x: 1000, y: 760, width: 1050, height: 125),
                     CGRect(x: 1000, y: 968, width: 1650, height: 125)]
        func marks(scale: CGFloat, raster: CGFloat) -> [Annotation] {
            let scaled = rects.map { CGRect(x: $0.minX * scale, y: $0.minY * scale,
                                           width: $0.width * scale, height: $0.height * scale) }
            return [Annotation(shape: .blur(scaled[0]), color: .red, lineWidth: 4, rasterScale: raster),
                    Annotation(shape: .pixelate(scaled[1]), color: .red, lineWidth: 4, rasterScale: raster)]
        }
        let whole = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        guard let expected = Renderer.flatten(image: source, scale: 1, selection: whole,
                                             annotations: marks(scale: 1, raster: 1 / fit)) else {
            throw NSError(domain: "ReviewReference", code: 1)
        }
        try save(expected, at: directory.appendingPathComponent("source-rendered-reference.png"))
        let fitSource = try resized(source, width: 928, height: 522)
        try save(fitSource, at: directory.appendingPathComponent("source-fit.png"))
        guard let screenshot = Renderer.flatten(image: fitSource, scale: 1,
                selection: CGRect(x: 0, y: 0, width: 928, height: 522), annotations: marks(scale: fit, raster: 1)) else {
            throw NSError(domain: "ReviewReference", code: 2)
        }
        try save(screenshot, at: directory.appendingPathComponent("screenshot-strength-reference.png"))
        try save(resized(expected, width: 928, height: 522),
                 at: directory.appendingPathComponent("source-rendered-reference-fit.png"))
        for quality in ["high", "balanced"] {
            for frame in ["01", "02", "03"] {
                let image = try load(directory.appendingPathComponent("\(quality)-\(frame).png"))
                try save(resized(image, width: 928, height: 522),
                         at: directory.appendingPathComponent("\(quality)-\(frame)-fit.png"))
            }
        }
        print("Rendered actual screenshot pipeline reference at 928×522; source coordinates, fit \(fit).")
    }

    static func load(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(domain: "ReviewReference", code: 3)
        }
        return image
    }
    static func save(_ image: CGImage, at url: URL) throws {
        guard let bytes = Renderer.encode(image, as: .png, quality: 1) else {
            throw NSError(domain: "ReviewReference", code: 4)
        }
        try bytes.write(to: url)
    }
    static func resized(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw NSError(domain: "ReviewReference", code: 5)
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage() else { throw NSError(domain: "ReviewReference", code: 6) }
        return resized
    }
}
