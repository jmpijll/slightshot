import AppKit
import Testing
@testable import Slightshot

@MainActor
struct ProductIconTests {
    @Test func allSharedVectorsRenderWithoutClippingAtBothScales() throws {
        for scale in [1, 2] {
            for icon in ProductIcon.allCases {
                let image = try render(icon, scale: scale)
                let side = image.width
                let data = try #require(image.dataProvider?.data)
                let bytes = try #require(CFDataGetBytePtr(data))
                var ink = 0
                for y in 0..<side {
                    for x in 0..<side {
                        let alpha = bytes[y * image.bytesPerRow + x * 4 + 3]
                        if alpha > 0 { ink += 1 }
                        if x == 0 || y == 0 || x == side - 1 || y == side - 1 {
                            #expect(alpha == 0, "\(icon.rawValue) clips at \(scale)×")
                        }
                    }
                }
                #expect(ink > 20 * scale, "\(icon.rawValue) must contain readable artwork")
                let template = icon.image(accessibilityDescription: icon.rawValue)
                #expect(template.isTemplate)
                #expect(template.size == CGSize(width: 18, height: 18))
                #expect(template.accessibilityDescription == icon.rawValue)
                if let directory = ProcessInfo.processInfo.environment["SLIGHTSHOT_ICON_EVIDENCE_DIR"] {
                    let url = URL(fileURLWithPath: directory, isDirectory: true)
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                    try png.write(to: url.appendingPathComponent("mac-\(icon.rawValue)-\(scale)x.png"))
                }
            }
        }
    }

    @Test func buttonsKeepSizeLabelsAndEnabledActionBehavior() {
        var clicks = 0
        let button = ToolbarButton(icon: .record, tooltip: "Record selected area") { clicks += 1 }
        #expect(button.intrinsicContentSize == CGSize(width: 30, height: 30))
        #expect(button.accessibilityLabel() == "Record selected area")
        button.performClick(nil)
        #expect(clicks == 1)
        button.isEnabled = false
        button.performClick(nil)
        #expect(clicks == 1)
    }

    private func render(_ icon: ProductIcon, scale: Int) throws -> CGImage {
        let side = 18 * scale
        let context = try #require(CGContext(data: nil, width: side, height: side,
                                            bitsPerComponent: 8, bytesPerRow: side * 4,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        icon.draw(in: context)
        return try #require(context.makeImage())
    }
}
