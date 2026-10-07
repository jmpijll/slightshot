import AppKit
import Testing
@testable import Slightshot

@MainActor
struct RasterEffectTests {
    @Test func blurChangesOnlyTheRequestedRegionAtBothScales() throws {
        for scale in [CGFloat(1), 2] {
            let source = try fixture(scale: scale)
            let selection = CGRect(x: 8, y: 4, width: 64, height: 48)
            let region = CGRect(x: 20, y: 12, width: 32, height: 24)
            let original = try #require(Renderer.flatten(image: source, scale: scale,
                                                         selection: selection, annotations: []))
            let blurred = try #require(Renderer.flatten(image: source, scale: scale,
                selection: selection, annotations: [annotation(.blur(region))]))
            #expect(blurred.width == Int(64 * scale))
            #expect(blurred.height == Int(48 * scale))
            #expect(pixel(blurred, x: Int(4 * scale), y: Int(4 * scale)) ==
                    pixel(original, x: Int(4 * scale), y: Int(4 * scale)))
            let center = pixel(blurred, x: Int(24 * scale), y: Int(16 * scale))
            #expect(center[0] > 40 && center[0] < 215)
            #expect(center != pixel(original, x: Int(24 * scale), y: Int(16 * scale)))
        }
    }

    @Test func pixelationMakesBlocksAndKeepsTheOutsideUntouched() throws {
        let source = try fixture(scale: 1)
        let selection = CGRect(x: 8, y: 4, width: 64, height: 48)
        let result = try #require(Renderer.flatten(image: source, scale: 1, selection: selection,
            annotations: [annotation(.pixelate(CGRect(x: 20, y: 12, width: 32, height: 24)))]))
        #expect(pixel(result, x: 15, y: 11) == pixel(result, x: 16, y: 11))
        #expect(pixel(result, x: 4, y: 4) == pixel(source, x: 12, y: 8))
        // A top-origin region must not obscure the vertically mirrored row.
        #expect(pixel(result, x: 15, y: 42) == pixel(source, x: 23, y: 46))
    }

    @Test func effectsRespectAnnotationOrderAndUndoRestoresTheSource() throws {
        let source = try fixture(scale: 1)
        let selection = CGRect(x: 0, y: 0, width: 80, height: 64)
        let line = Annotation(shape: .line(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 60, y: 20)),
                              color: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), lineWidth: 4)
        let blur = annotation(.blur(CGRect(x: 8, y: 8, width: 64, height: 40)))
        let before = try #require(Renderer.flatten(image: source, scale: 1,
                                                   selection: selection, annotations: [line, blur]))
        let after = try #require(Renderer.flatten(image: source, scale: 1,
                                                  selection: selection, annotations: [blur, line]))
        #expect(pixel(before, x: 40, y: 20)[1] > pixel(after, x: 40, y: 20)[1] + 40)
        #expect(pixel(after, x: 40, y: 20)[1] < 80)
        let restored = try #require(Renderer.flatten(image: source, scale: 1,
                                                     selection: selection, annotations: []))
        #expect(pixel(restored, x: 40, y: 20) == pixel(source, x: 40, y: 20))
    }

    @Test func clippedAndTinyRegionsStayOpaque() throws {
        let source = try fixture(scale: 2)
        let selection = CGRect(x: 0, y: 0, width: 80, height: 64)
        for shape in [Annotation.Shape.blur(CGRect(x: -5, y: -5, width: 12, height: 12)),
                      .pixelate(CGRect(x: 79, y: 63, width: 1, height: 1)),
                      .blur(CGRect(x: 10, y: 10, width: 0, height: 0))] {
            let image = try #require(Renderer.flatten(image: source, scale: 2,
                                                       selection: selection, annotations: [annotation(shape)]))
            #expect(pixel(image, x: 0, y: 0)[3] == 255)
            #expect(pixel(image, x: 159, y: 127)[3] == 255)
        }
    }

    @Test func liveAndCommittedCanvasMatchExportAndUndoAtBothScales() throws {
        for scale in [CGFloat(1), 2] {
            let source = try fixture(scale: scale)
            let selection = CGRect(x: 8, y: 4, width: 64, height: 48)
            let region = CGRect(x: 20, y: 12, width: 32, height: 24)
            let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 80, height: 64))
            canvas.sourceImage = source
            canvas.imageScale = scale
            canvas.selection = selection
            canvas.showDimensions = false
            for shape in [Annotation.Shape.blur(region), .pixelate(region)] {
                let effect = annotation(shape)
                let exported = try #require(Renderer.flatten(image: source, scale: scale,
                    selection: selection, annotations: [effect]))
                canvas.annotations = []
                canvas.liveAnnotation = effect
                let live = try renderCanvas(canvas, source: source, scale: scale)
                canvas.annotations = [effect]
                canvas.liveAnnotation = nil
                let committed = try renderCanvas(canvas, source: source, scale: scale)
                for point in [(24, 16), (36, 24), (4, 40)] {
                    let expected = pixel(exported, x: Int(CGFloat(point.0) * scale), y: Int(CGFloat(point.1) * scale))
                    let x = Int(CGFloat(point.0 + 8) * scale), y = Int(CGFloat(point.1 + 4) * scale)
                    #expect(pixel(live, x: x, y: y) == expected)
                    #expect(pixel(committed, x: x, y: y) == expected)
                }
                canvas.annotations = []
                let undone = try renderCanvas(canvas, source: source, scale: scale)
                #expect(pixel(undone, x: Int(32 * scale), y: Int(20 * scale)) ==
                        pixel(source, x: Int(32 * scale), y: Int(20 * scale)))
            }
        }
    }

    @Test func fractionalZeroWidthOrHeightDoesNotModifyAnyPixels() throws {
        let source = try fixture(scale: 2)
        let selection = CGRect(x: 0, y: 0, width: 80, height: 64)
        for rect in [CGRect(x: 10.1, y: 10.1, width: 0, height: 12.5),
                     CGRect(x: 10.1, y: 10.1, width: 12.5, height: 0)] {
            for shape in [Annotation.Shape.blur(rect), .pixelate(rect)] {
                let rendered = try #require(Renderer.flatten(image: source, scale: 2,
                    selection: selection, annotations: [annotation(shape)]))
                #expect(pixel(rendered, x: 20, y: 20) == pixel(source, x: 20, y: 20))
                #expect(pixel(rendered, x: 20, y: 24) == pixel(source, x: 20, y: 24))
                #expect(pixel(rendered, x: 24, y: 20) == pixel(source, x: 24, y: 20))
            }
        }
    }

    private func renderCanvas(_ canvas: CanvasView, source: CGImage, scale: CGFloat) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: source.width, height: source.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        context.translateBy(x: 0, y: CGFloat(source.height))
        context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        canvas.draw(canvas.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return try #require(context.makeImage())
    }

    private func annotation(_ shape: Annotation.Shape) -> Annotation {
        Annotation(shape: shape, color: .red, lineWidth: 2)
    }

    private func fixture(scale: CGFloat) throws -> CGImage {
        let width = Int(80 * scale), height = Int(64 * scale)
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let gray: UInt8 = ((Int(CGFloat(x) / scale) / 2 + Int(CGFloat(y) / scale) / 2) % 2 == 0) ? 0 : 255
                let offset = (y * width + x) * 4
                bytes[offset] = gray
                bytes[offset + 1] = gray
                bytes[offset + 2] = gray
            }
        }
        let data = Data(bytes) as CFData
        let provider = try #require(CGDataProvider(data: data))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        guard let crop = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return [] }
        let rep = NSBitmapImageRep(cgImage: crop)
        guard let color = rep.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB) else { return [] }
        return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
            .map { UInt8(max(0, min(255, ($0 * 255).rounded()))) }
    }
}
