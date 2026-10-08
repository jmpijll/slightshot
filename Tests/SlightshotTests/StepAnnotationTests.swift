import AppKit
import Testing
@testable import Slightshot

@MainActor
struct StepAnnotationTests {
    @Test func numberedStepsAreAvailableAfterTheExistingTools() throws {
        let step = try #require(Tool(rawValue: "step"))
        #expect(Tool.allCases.last == step)
        #expect(Tool.allCases.prefix(8).map(\.rawValue) ==
                ["pen", "line", "arrow", "rectangle", "marker", "text", "blur", "pixelate"])
        #expect(step.usesColorAndWidth)
    }

    @Test func undoRestoresTheNextNumberAndOtherMarksDoNotAdvanceIt() {
        var history = [stamp(1), Annotation(shape: .text("99", origin: .zero), color: .red, lineWidth: 3),
                       stamp(9), stamp(10)]
        #expect(Annotation.nextStepNumber(in: history) == 11)
        history.removeLast()
        #expect(Annotation.nextStepNumber(in: history) == 10)
        history.removeLast()
        #expect(Annotation.nextStepNumber(in: history) == 2)
        #expect(Annotation.nextStepNumber(in: []) == 1)
    }

    @Test func circlesGrowForDigitsAndIgnoreThickness() throws {
        let source = try fixture(scale: 1)
        let selection = CGRect(x: 0, y: 0, width: 120, height: 100)
        let one = stamp(1, center: CGPoint(x: 60, y: 50))
        let three = stamp(100, center: CGPoint(x: 60, y: 50))
        let thin = try #require(Renderer.flatten(image: source, scale: 1, selection: selection, annotations: [one]))
        var thickStamp = one
        thickStamp.lineWidth = 12
        thickStamp.fontSize = 40
        let thick = try #require(Renderer.flatten(image: source, scale: 1, selection: selection,
                                                 annotations: [thickStamp]))
        let wide = try #require(Renderer.flatten(image: source, scale: 1, selection: selection,
                                                annotations: [three]))
        #expect(bytes(thin) == bytes(thick))
        #expect(pixel(thin, x: 40, y: 50) == [0, 0, 0, 255])
        #expect(pixel(wide, x: 40, y: 50)[0] > 240)
        #expect(three.dirtyBounds.contains(CGPoint(x: 34, y: 50)))
        #expect(bytes(thin) != bytes(wide))
    }

    @Test func stepLiveAndCommittedPixelsMatchExportWithRasterHistory() throws {
        for scale in [CGFloat(1), 2] {
            let source = try fixture(scale: scale)
            let selection = CGRect(x: 8, y: 8, width: 96, height: 72)
            let step = stamp(12, center: CGPoint(x: 56, y: 44))
            let effect = Annotation(shape: .pixelate(CGRect(x: 16, y: 16, width: 72, height: 48)),
                                    color: .red, lineWidth: 2)
            for history in [[Annotation](), [stamp(1, center: CGPoint(x: 28, y: 28)), effect]] {
                let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 120, height: 100))
                canvas.sourceImage = source
                canvas.imageScale = scale
                canvas.selection = selection
                canvas.showDimensions = false
                canvas.annotations = history
                canvas.liveAnnotation = step
                let live = try render(canvas, source: source, scale: scale)
                canvas.annotations.append(step)
                canvas.liveAnnotation = nil
                let committed = try render(canvas, source: source, scale: scale)
                let exported = try #require(Renderer.flatten(image: source, scale: scale,
                    selection: selection, annotations: history + [step]))
                let interior = CGRect(x: 20 * scale, y: 20 * scale, width: 56 * scale, height: 40 * scale)
                let previewRect = interior.offsetBy(dx: 8 * scale, dy: 8 * scale)
                #expect(bytes(try #require(live.cropping(to: previewRect))) ==
                        bytes(try #require(exported.cropping(to: interior))))
                #expect(bytes(try #require(committed.cropping(to: previewRect))) ==
                        bytes(try #require(exported.cropping(to: interior))))
                canvas.annotations = history
                let undone = try render(canvas, source: source, scale: scale)
                #expect(pixel(undone, x: Int(66 * scale), y: Int(44 * scale)) == [0, 0, 0, 255])
                #expect(pixel(exported, x: Int(58 * scale), y: Int(36 * scale))[0] > 240)
            }
        }
    }

    @Test func rasterEffectsTransformEarlierStepsAndPreserveLaterSteps() throws {
        for scale in [CGFloat(1), 2] {
            let source = try fixture(scale: scale)
            let selection = CGRect(x: 0, y: 0, width: 120, height: 100)
            let step = stamp(1, center: CGPoint(x: 56, y: 44))
            for shape in [Annotation.Shape.blur(CGRect(x: 16, y: 16, width: 80, height: 64)),
                          .pixelate(CGRect(x: 16, y: 16, width: 80, height: 64))] {
                let effect = Annotation(shape: shape, color: .red, lineWidth: 2)
                let before = try #require(Renderer.flatten(image: source, scale: scale,
                    selection: selection, annotations: [step, effect]))
                let after = try #require(Renderer.flatten(image: source, scale: scale,
                    selection: selection, annotations: [effect, step]))
                #expect(bytes(before) != bytes(after))
                #expect(pixel(after, x: Int(66 * scale), y: Int(44 * scale))[0] > 240)
                #expect(pixel(before, x: Int(66 * scale), y: Int(44 * scale))[0] < 235)
            }
        }
    }

    @Test func stepsClipAtSelectionEdgesAndLightColoursKeepDarkDigits() throws {
        let source = try fixture(scale: 1)
        let selection = CGRect(x: 8, y: 8, width: 96, height: 72)
        var step = stamp(1, center: CGPoint(x: 10, y: 44))
        step.color = .white
        let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 120, height: 100))
        canvas.sourceImage = source
        canvas.selection = selection
        canvas.annotations = [step]
        canvas.showDimensions = false
        let preview = try render(canvas, source: source, scale: 1)
        let exported = try #require(Renderer.flatten(image: source, scale: 1,
            selection: selection, annotations: [step]))
        #expect(exported.width == 96 && exported.height == 72)
        #expect(pixel(preview, x: 2, y: 44) == [0, 0, 0, 255])
        #expect(pixel(exported, x: 8, y: 36) == [255, 255, 255, 255])
        let glyph = try #require(exported.cropping(to: CGRect(x: 0, y: 27, width: 7, height: 18)))
        #expect(bytes(glyph).contains { $0 < 80 })
    }

    private func stamp(_ number: Int, center: CGPoint = .zero) -> Annotation {
        Annotation(shape: .step(number: number, center: center),
                   color: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), lineWidth: 3)
    }

    private func fixture(scale: CGFloat) throws -> CGImage {
        let width = Int(120 * scale), height = Int(100 * scale)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func render(_ canvas: CanvasView, source: CGImage, scale: CGFloat) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: source.width, height: source.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        context.translateBy(x: 0, y: CGFloat(source.height))
        context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        canvas.draw(canvas.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return try #require(context.makeImage())
    }

    private func bytes(_ image: CGImage) -> [UInt8] {
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = context.data else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
                                        count: image.width * image.height * 4))
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return [] }
        return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
            .map { UInt8(max(0, min(255, ($0 * 255).rounded()))) }
    }
}
