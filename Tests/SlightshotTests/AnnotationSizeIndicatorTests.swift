import AppKit
import Testing
@testable import Slightshot

@MainActor
struct AnnotationSizeIndicatorTests {
    @Test func haloGrowsContinuouslyWithStrokeAndTextSize() {
        #expect(AnnotationSizeChange(isText: false, value: 1).indicatorDiameter == 18)
        #expect(AnnotationSizeChange(isText: false, value: 12).indicatorDiameter == 54)
        let diameters = (1...12).map { AnnotationSizeChange(isText: false, value: CGFloat($0)).indicatorDiameter }
        #expect(diameters == diameters.sorted())
        #expect(Set(diameters).count == 12)
        #expect(AnnotationSizeChange(isText: true, value: 10).indicatorDiameter == 18)
        #expect(AnnotationSizeChange(isText: true, value: 48).indicatorDiameter == 54)
        #expect(AnnotationSizeChange(isText: true, value: 26).indicatorDiameter < 40)
        #expect(AnnotationSizeChange(isText: false, value: -10).indicatorDiameter == 18)
        #expect(AnnotationSizeChange(isText: false, value: 100).indicatorDiameter == 54)
        #expect(AnnotationSizeChange(isText: false, value: .nan).indicatorDiameter == 18)
    }

    @Test func haloStaysCenteredOnPointerEvenAtViewportEdges() {
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 180))
        let halo = AnnotationSizeIndicator()
        halo.show(AnnotationSizeChange(isText: false, value: 9), at: CGPoint(x: 2, y: 3), in: host)
        #expect(halo.frame.midX == 2)
        #expect(halo.frame.midY == 3)
        #expect(halo.frame.width == halo.frame.height)
        #expect(halo.frame.minX < 0)
        #expect(halo.accessibilityLabel() == "Thickness 9 pt")
        #expect(!halo.subviews.contains { $0 is NSTextField })
        #expect(halo.hitTest(.zero) == nil)
        halo.hide()
    }

    @Test func haloFollowsPointerAndSizeChangesKeepItsCenter() {
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 180))
        let halo = AnnotationSizeIndicator()
        halo.show(AnnotationSizeChange(isText: false, value: 1), at: CGPoint(x: 100, y: 80), in: host)
        halo.move(to: CGPoint(x: 200, y: 120), in: host)
        #expect(halo.frame.midX == 200)
        #expect(halo.frame.midY == 120)
        halo.show(AnnotationSizeChange(isText: false, value: 12), at: CGPoint(x: 200, y: 120), in: host)
        #expect(halo.frame.midX == 200)
        #expect(halo.frame.midY == 120)
        #expect(halo.frame.width == 54)
        halo.show(AnnotationSizeChange(isText: false, value: 1), at: CGPoint(x: 200, y: 120), in: host)
        #expect(halo.frame.width == 18)
        halo.hide()
        let hiddenFrame = halo.frame
        halo.move(to: .zero, in: host)
        #expect(halo.frame == hiddenFrame)
    }
}
