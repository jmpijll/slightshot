import AppKit

extension ProductIcon {
    func image(accessibilityDescription: String) -> NSImage {
        let image = NSImage(size: CGSize(width: Self.size, height: Self.size), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setStrokeColor(CGColor(gray: 0, alpha: 1))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            self.draw(in: context)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }
}
