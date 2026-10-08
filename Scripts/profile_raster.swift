// Compile with RasterEffect.swift; see docs/review/performance/README.md.
import AppKit
import CryptoKit
import Foundation

@main struct RasterProfile {
    @MainActor static func main() throws {
        let width = 3840, height = 2160
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let offset = (y * width + x) * 4
            pixels[offset] = UInt8(truncatingIfNeeded: x * 3 + y)
            pixels[offset + 1] = UInt8(truncatingIfNeeded: y * 7 + x)
            pixels[offset + 2] = UInt8(truncatingIfNeeded: x ^ y)
        }}
        let source = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)!
        var rows = [[String: Any]]()
        for (name, rect) in [("400x200", CGRect(x: 0, y: 0, width: 400, height: 200)),
                             ("1920x1080", CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                             ("3840x2160", CGRect(x: 0, y: 0, width: 3840, height: 2160))] {
            var operations: [(String, () -> CGImage)] = [
                ("current", { RasterEffects.render(.pixelate, image: source, pixels: rect, scale: 1)! })
            ]
#if COMPARE_BASELINE
            operations.append(("baseline", {
                BaselineRasterEffects.render(.pixelate, image: source, pixels: rect, scale: 1)!
            }))
#endif
            var samples = [String: [Double]]()
            var hashes = [String: String]()
            for iteration in 0..<41 {
                let ordered = iteration.isMultiple(of: 2) ? operations : Array(operations.reversed())
                for (label, operation) in ordered {
                    autoreleasepool {
                        let start = ContinuousClock.now
                        let result = operation()
                        let elapsed = start.duration(to: .now).components
                        precondition(result.width == Int(rect.width) && result.height == Int(rect.height))
                        if iteration == 0 {
                            let data = result.dataProvider!.data! as Data
                            hashes[label] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                        } else {
                            samples[label, default: []].append(
                                Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
                        }
                    }
                }
            }
            precondition(Set(hashes.values).count == 1, "Pixel output changed")
            for (label, values) in samples {
                let ordered = values.sorted()
                rows.append(["size": name, "implementation": label, "warm_samples": values.count,
                             "median_ms": ordered[20], "p95_ms": ordered[37], "rgba_sha256": hashes[label]!])
            }
        }
        let report: [String: Any] = ["fixture": "Synthetic opaque sRGB RGBA gradient; no screen capture",
                                   "scale": 1, "os": ProcessInfo.processInfo.operatingSystemVersionString,
                                   "rows": rows]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
