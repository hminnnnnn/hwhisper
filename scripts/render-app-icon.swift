#!/usr/bin/env swift
// Renders the hwhisper app icon (brand: 먹/ink × 청자/celadon — a whisper
// waveform settling into a line of text) at every .icns size and assembles
// assets/AppIcon.icns via iconutil. CoreGraphics-only so it runs on the
// CLT-only host (no Xcode / Icon Composer — macOS 26 wraps classic .icns in
// its glass tile automatically, so we follow the "centered symbol, breathing
// room" guidance instead of shipping a Liquid Glass .icon folder).
//
// Usage: swift scripts/render-app-icon.swift [output-dir]   (default: assets)

import AppKit
import CoreGraphics

// MARK: - Brand constants (keep in sync with Sources/HwhisperMac/BrandTheme.swift)

let inkTop = NSColor(srgbRed: 0.075, green: 0.106, blue: 0.180, alpha: 1)      // #131B2E
let inkBottom = NSColor(srgbRed: 0.039, green: 0.059, blue: 0.102, alpha: 1)   // #0A0F1A
let celadonLight = NSColor(srgbRed: 0.647, green: 0.933, blue: 0.863, alpha: 1) // #A5EEDC
let celadonDeep = NSColor(srgbRed: 0.275, green: 0.725, blue: 0.612, alpha: 1)  // #46B99C
let celadonDash = NSColor(srgbRed: 0.498, green: 0.847, blue: 0.761, alpha: 1)  // #7FD8C2

/// Draws the 1024-grid icon into the current graphics context, scaled to
/// `size`. All geometry below is authored on a 1024pt canvas.
func drawIcon(size: CGFloat) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no context") }
    let s = size / 1024.0
    ctx.scaleBy(x: s, y: s)

    // Big Sur+ grid: the squircle occupies ~824/1024 centered, with the
    // rest as transparent margin (Finder/Dock add their own shadow).
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let radius: CGFloat = 186
    let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Soft drop shadow behind the tile (subtle — classic icns convention).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 36,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(tilePath)
    ctx.setFillColor(inkBottom.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Ink background gradient, clipped to the squircle.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [inkTop.cgColor, inkBottom.cgColor] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Celadon "breath" glow rising from below the glyph — the whisper.
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [celadonDeep.withAlphaComponent(0.22).cgColor,
                                   celadonDeep.withAlphaComponent(0).cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 400), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 400), endRadius: 520, options: [])

    // Hairline top rim light for a quiet glassy edge.
    ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 3, dy: 3), cornerWidth: radius - 3, cornerHeight: radius - 3, transform: nil))
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.07).cgColor)
    ctx.setLineWidth(6)
    ctx.strokePath()

    // Glyph: four waveform bars settling into a horizontal dash — 말이
    // 글이 되는 순간. Rounded caps everywhere; centered on the canvas.
    let barWidth: CGFloat = 74
    let gap: CGFloat = 56
    let dashWidth: CGFloat = 190
    let heights: [CGFloat] = [200, 396, 560, 300]
    let centerY: CGFloat = 512
    let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count) * gap + dashWidth
    var x = (1024 - totalWidth) / 2

    let barGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [celadonLight.cgColor, celadonDeep.cgColor] as CFArray,
                                 locations: [0, 1])!

    for height in heights {
        let rect = CGRect(x: x, y: centerY - height / 2, width: barWidth, height: height)
        let path = CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.drawLinearGradient(barGradient,
                               start: CGPoint(x: rect.midX, y: rect.maxY),
                               end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        ctx.restoreGState()
        x += barWidth + gap
    }

    // The settling dash (text line), vertically centered like the bars.
    let dashRect = CGRect(x: x, y: centerY - barWidth / 2, width: dashWidth, height: barWidth)
    ctx.addPath(CGPath(roundedRect: dashRect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
    ctx.setFillColor(celadonDash.cgColor)
    ctx.fillPath()

    ctx.restoreGState()
}

func renderPNG(pixels: Int, to url: URL) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(size: CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let outputDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets")
let iconset = outputDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for entry in sizes {
    renderPNG(pixels: entry.pixels, to: iconset.appendingPathComponent("\(entry.name).png"))
}
// A loose 256px preview for docs/brand board.
renderPNG(pixels: 256, to: outputDir.appendingPathComponent("AppIcon-preview.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputDir.appendingPathComponent("AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
try? FileManager.default.removeItem(at: iconset)
print("wrote \(outputDir.path)/AppIcon.icns (+ AppIcon-preview.png)")
