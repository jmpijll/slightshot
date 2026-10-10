import AppKit

@main enum ProductionBlurProbe {
    static func main() {
        let scale: CGFloat = 1.0344827586206897
        let warm = CommandLine.arguments.dropFirst().first == "warm"
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 960, height: 540, bitsPerComponent: 8,
            bytesPerRow: 960 * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 960, height: 540))
        let source = context.makeImage()!
        if warm {
            let start = ProcessInfo.processInfo.systemUptime
            RasterEffects.prewarmBlur(scale: scale)
            print("prewarmMs=\((ProcessInfo.processInfo.systemUptime-start)*1000)")
        }
        for iteration in 0..<10 {
            let start = ProcessInfo.processInfo.systemUptime
            let image = RasterEffects.render(.blur, image: source,
                pixels: CGRect(x: 250, y: 190, width: 263, height: 32), scale: scale)!
            print("mode=\(warm ? "warm" : "cold") iteration=\(iteration) image=\(image.width)x\(image.height) totalMs=\((ProcessInfo.processInfo.systemUptime-start)*1000)")
        }
    }
}
