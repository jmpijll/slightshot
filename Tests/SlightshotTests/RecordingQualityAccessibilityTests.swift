import AppKit
import Testing
@testable import Slightshot

@MainActor
struct RecordingQualityAccessibilityTests {
    @Test func nativeSliderSupportsNumericValuesAndActions() throws {
        let view = RecordingQualityView(quality: .balanced, sourceSize: CGSize(width: 2048, height: 1200))
        let stack = try #require(view.subviews.first as? NSStackView)
        let slider = try #require(stack.arrangedSubviews.compactMap { $0 as? NSSlider }.first)
        let cell = try #require(slider.cell as? NSSliderCell)

        // AppKit exposes the slider's cell as its native accessibility element.
        #expect((cell.accessibilityValue() as? NSNumber)?.intValue == RecordingQuality.balanced.rawValue)
        #expect(slider.accessibilityValueDescription() == RecordingQuality.balanced.title)
        _ = cell.accessibilityPerformIncrement()
        #expect(view.quality == .high)
        #expect((cell.accessibilityValue() as? NSNumber)?.intValue == RecordingQuality.high.rawValue)
        #expect(slider.accessibilityValueDescription() == RecordingQuality.high.title)
        _ = cell.accessibilityPerformDecrement()
        #expect(view.quality == .balanced)

        cell.setAccessibilityValue(NSNumber(value: RecordingQuality.compact.rawValue))
        #expect(view.quality == .compact)
        #expect((cell.accessibilityValue() as? NSNumber)?.intValue == RecordingQuality.compact.rawValue)
        #expect(slider.accessibilityValueDescription() == RecordingQuality.compact.title)
    }
}
