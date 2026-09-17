#!/usr/bin/env swift
// Renders Slightshot's app icon into an .iconset directory.
// Usage: swift Scripts/make_icon.swift <output.iconset>

import AppKit
import Foundation

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
let outputURL = URL(fileURLWithPath: outputPath)
try? FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

// One mark supplies the app icon, menu-bar template and README header.
let corners: [[CGPoint]] = [
    [CGPoint(x: 290, y: 450), CGPoint(x: 290, y: 290), CGPoint(x: 450, y: 290)],
    [CGPoint(x: 574, y: 734), CGPoint(x: 734, y: 734), CGPoint(x: 734, y: 574)],
    [CGPoint(x: 290, y: 574), CGPoint(x: 290, y: 734), CGPoint(x: 450, y: 734)],
]
let arrow: [[CGPoint]] = [
    [CGPoint(x: 452, y: 572), CGPoint(x: 734, y: 290)],
    [CGPoint(x: 568, y: 290), CGPoint(x: 734, y: 290), CGPoint(x: 734, y: 456)],
]
let cream = NSColor(srgbRed: 0.94, green: 0.95, blue: 0.91, alpha: 1)
let apricot = NSColor(srgbRed: 0.96, green: 0.65, blue: 0.49, alpha: 1)

func stroke(_ lines: [[CGPoint]], colour: NSColor) {
    let path = NSBezierPath()
    path.lineWidth = 58
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    for points in lines {
        path.move(to: points[0])
        for point in points.dropFirst() { path.line(to: point) }
    }
    colour.setStroke()
    path.stroke()
}

func drawIcon(side: CGFloat, template: Bool = false) {
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.saveGState()
    defer { ctx.restoreGState() }
    ctx.translateBy(x: 0, y: side)
    ctx.scaleBy(x: side / 1024, y: -side / 1024)
    if template {
        ctx.translateBy(x: -400, y: -400)
        ctx.scaleBy(x: 1.78, y: 1.78)
    } else {
        let plate = NSBezierPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                                 xRadius: 185, yRadius: 185)
        NSGradient(colors: [
            NSColor(srgbRed: 0.23, green: 0.36, blue: 0.32, alpha: 1),
            NSColor(srgbRed: 0.10, green: 0.19, blue: 0.17, alpha: 1),
        ])!.draw(in: plate, angle: 90)
    }
    stroke(corners, colour: template ? .black : cream)
    stroke(arrow, colour: template ? .black : apricot)
}

func writePNG(side: Int, to url: URL, template: Bool = false) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { throw NSError(domain: "icon", code: 1) }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(side: CGFloat(side), template: template)
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

try writePNG(side: 1024, to: URL(fileURLWithPath: "docs/icon.png"))
try writePNG(side: 36, to: URL(fileURLWithPath: "Resources/MenuBarTemplate.png"), template: true)

func svgPath(_ lines: [[CGPoint]]) -> String {
    lines.map { points in
        points.enumerated().map { index, point in
            "\(index == 0 ? "M" : "L")\(Int(point.x)) \(Int(point.y))"
        }.joined(separator: " ")
    }.joined(separator: " ")
}
let mark = """
<g fill="none" stroke-width="58" stroke-linecap="round" stroke-linejoin="round">
  <path d="\(svgPath(corners))" stroke="#f0f2e8"/>
  <path d="\(svgPath(arrow))" stroke="#f5a67d"/>
</g>
"""
let hero = """
<svg xmlns="http://www.w3.org/2000/svg" width="1440" height="480" viewBox="0 0 1440 480" role="img" aria-label="Slightshot. A screenshot with your point on it.">
<defs><linearGradient id="bg" x2="1" y2="1"><stop stop-color="#1a302b"/><stop offset="1" stop-color="#3b5c52"/></linearGradient></defs>
<rect width="1440" height="480" rx="28" fill="url(#bg)"/>
<g transform="translate(790 -85) scale(.7)">\(mark)</g>
<g font-family="Inter,Segoe UI,Arial,sans-serif">
<text x="80" y="113" fill="#f0f2e8" font-size="35" font-weight="600" letter-spacing="-1">Slightshot</text>
<text x="80" y="240" fill="#f0f2e8" font-size="64" font-weight="600" letter-spacing="-2">A screenshot with</text>
<text x="80" y="316" fill="#f5a67d" font-size="64" letter-spacing="-2">your point on it.</text>
<text x="84" y="410" fill="#b8ccc4" font-size="15" letter-spacing="2.5">SCREENSHOTS FOR MACOS / OPEN SOURCE</text>
</g></svg>
"""
try hero.write(toFile: "docs/hero.svg", atomically: true, encoding: .utf8)
