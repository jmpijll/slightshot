// Render offscreen production AppKit controls for review; no live mouse input.
import AppKit

@main
@MainActor
struct IconReview {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/icon-review", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 30, height: 30), styleMask: [], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let icons = ProductIcon.allCases
        for scale in [1, 2] {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 760 * scale, pixelsHigh: 280 * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
            NSGraphicsContext.saveGraphicsState()
            let context = graphics.cgContext
            context.translateBy(x: 0, y: CGFloat(280 * scale))
            context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            NSColor(calibratedWhite: 0.09, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 760, height: 280).fill()
            func label(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat) {
                (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.white])
            }
            label("Slightshot · native AppKit buttons", x: 18, y: 18, size: 14)
            for (column, icon) in icons.enumerated() {
                let x = CGFloat(112 + column * 39)
                label(icon.rawValue.capitalized, x: x - 2, y: 60, size: 7)
                for (row, name) in ["Normal", "Hover style", "Selected", "Disabled"].enumerated() {
                    let y = CGFloat(76 + row * 46)
                    if column == 0 { label(name, x: 18, y: y + 10, size: 11) }
                    let button = ToolbarButton(icon: icon, tooltip: icon.rawValue, onClick: {})
                    window.contentView = button
                    button.isSelectedItem = row == 2
                    button.isEnabled = row != 3
                    if row == 1 { button.mouseEntered(with: NSEvent()) }
                    button.layoutSubtreeIfNeeded()
                    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 30 * scale, pixelsHigh: 30 * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    rep.size = NSSize(width: 30, height: 30)
                    button.cacheDisplay(in: button.bounds, to: rep)
                    let rendered = NSImage(size: NSSize(width: 30, height: 30))
                    rendered.addRepresentation(rep)
                    rendered.draw(in: NSRect(x: x, y: y, width: 30, height: 30), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            let path = directory.appendingPathComponent("icons-mac-\(scale)x.png").path
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
            print(path)
        }
    }
}
