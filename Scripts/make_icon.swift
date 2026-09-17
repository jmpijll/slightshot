#!/usr/bin/env swift
// Renders Slightshot's app icon into an .iconset directory.
// Usage: swift Scripts/make_icon.swift <output.iconset>

import AppKit
import Foundation

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
let outputURL = URL(fileURLWithPath: outputPath)
try? FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

/// Draws the icon into a canvas of `side` points using a 1024-based design grid.
func drawIcon(side: CGFloat) {
    let s = side / 1024
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS app icons sit inside the canvas with a margin.
    let plateRect = CGRect(x: 100 * s, y: 90 * s, width: 824 * s, height: 824 * s)
    let plate = NSBezierPath(roundedRect: plateRect, xRadius: 185 * s, yRadius: 185 * s)

    // Drop shadow under the plate.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 28 * s,
                  color: NSColor.black.withAlphaComponent(0.28).cgColor)
    NSColor.black.setFill()
    plate.fill()
    ctx.restoreGState()

    // Blue-to-violet gradient body.
    ctx.saveGState()
    plate.addClip()
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.24, green: 0.52, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.42, green: 0.27, blue: 0.95, alpha: 1),
    ])!
    gradient.draw(in: plateRect, angle: -90)

    // Soft top highlight.
    let highlight = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.30),
        NSColor.white.withAlphaComponent(0.0),
    ])!
    highlight.draw(in: CGRect(x: plateRect.minX, y: plateRect.midY,
                              width: plateRect.width, height: plateRect.height / 2), angle: -90)
    ctx.restoreGState()

    // Marquee: four corner brackets, like a selection being dragged out.
    let marquee = CGRect(x: 268 * s, y: 258 * s, width: 488 * s, height: 488 * s)
    let arm = 132 * s
    let weight = 46 * s
    NSColor.white.setStroke()

    let brackets = NSBezierPath()
    brackets.lineWidth = weight
    brackets.lineCapStyle = .round
    brackets.lineJoinStyle = .round

    // Top-left
    brackets.move(to: CGPoint(x: marquee.minX, y: marquee.maxY - arm))
    brackets.line(to: CGPoint(x: marquee.minX, y: marquee.maxY))
    brackets.line(to: CGPoint(x: marquee.minX + arm, y: marquee.maxY))
    // Top-right
    brackets.move(to: CGPoint(x: marquee.maxX - arm, y: marquee.maxY))
    brackets.line(to: CGPoint(x: marquee.maxX, y: marquee.maxY))
    brackets.line(to: CGPoint(x: marquee.maxX, y: marquee.maxY - arm))
    // Bottom-right
    brackets.move(to: CGPoint(x: marquee.maxX, y: marquee.minY + arm))
    brackets.line(to: CGPoint(x: marquee.maxX, y: marquee.minY))
    brackets.line(to: CGPoint(x: marquee.maxX - arm, y: marquee.minY))
    // Bottom-left
    brackets.move(to: CGPoint(x: marquee.minX + arm, y: marquee.minY))
    brackets.line(to: CGPoint(x: marquee.minX, y: marquee.minY))
    brackets.line(to: CGPoint(x: marquee.minX, y: marquee.minY + arm))

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * s), blur: 16 * s,
                  color: NSColor.black.withAlphaComponent(0.25).cgColor)
    brackets.stroke()
    ctx.restoreGState()

    // Centre crosshair.
    let centre = CGPoint(x: marquee.midX, y: marquee.midY)
    let crossArm = 74 * s
    let cross = NSBezierPath()
    cross.lineWidth = weight * 0.72
    cross.lineCapStyle = .round
    cross.move(to: CGPoint(x: centre.x - crossArm, y: centre.y))
    cross.line(to: CGPoint(x: centre.x + crossArm, y: centre.y))
    cross.move(to: CGPoint(x: centre.x, y: centre.y - crossArm))
    cross.line(to: CGPoint(x: centre.x, y: centre.y + crossArm))
    NSColor.white.withAlphaComponent(0.92).setStroke()
    cross.stroke()
}

func writePNG(side: Int, to url: URL) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { throw NSError(domain: "icon", code: 1) }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(side: CGFloat(side))
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 2)
    }
    try data.write(to: url)
}

let variants: [(name: String, side: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    try writePNG(side: variant.side, to: outputURL.appendingPathComponent("\(variant.name).png"))
}
print("Wrote \(variants.count) images to \(outputURL.path)")
