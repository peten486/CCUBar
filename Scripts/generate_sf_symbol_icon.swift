#!/usr/bin/env swift
// Generates a macOS iconset PNG set from a single SF Symbol, rendered white on a
// blue→green gradient rounded-rect background (matches the menu-bar tier palette).
// Usage: swift generate_sf_symbol_icon.swift <symbol-name> <output.iconset>

import AppKit

guard CommandLine.arguments.count == 3 else {
    fputs("usage: generate_sf_symbol_icon.swift <symbol-name> <output.iconset>\n", stderr)
    exit(64)
}

let symbolName = CommandLine.arguments[1]
let outputDir = URL(fileURLWithPath: CommandLine.arguments[2])
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

guard NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) != nil else {
    fputs("SF Symbol not found: \(symbolName)\n", stderr)
    exit(1)
}

let targets: [(size: Int, name: String)] = [
    (16,   "icon_16x16.png"),
    (32,   "icon_16x16@2x.png"),
    (32,   "icon_32x32.png"),
    (64,   "icon_32x32@2x.png"),
    (128,  "icon_128x128.png"),
    (256,  "icon_128x128@2x.png"),
    (256,  "icon_256x256.png"),
    (512,  "icon_256x256@2x.png"),
    (512,  "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

func renderIcon(size: Int) -> Data? {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    let canvas = NSRect(x: 0, y: 0, width: size, height: size)

    // Apple HIG: keep the glyph within a squircle that's ~82% of the canvas.
    let inset = CGFloat(size) * 0.09
    let bgRect = canvas.insetBy(dx: inset, dy: inset)
    let corner = bgRect.width * 0.22
    let path = NSBezierPath(roundedRect: bgRect, xRadius: corner, yRadius: corner)

    let gradient = NSGradient(colors: [
        NSColor(red: 0.22, green: 0.50, blue: 0.95, alpha: 1.0),   // top-left blue
        NSColor(red: 0.18, green: 0.78, blue: 0.55, alpha: 1.0)    // bottom-right green
    ])!
    gradient.draw(in: path, angle: 135)

    // Subtle inner highlight for depth
    let highlight = NSBezierPath(roundedRect: bgRect, xRadius: corner, yRadius: corner)
    NSColor.white.withAlphaComponent(0.08).setStroke()
    highlight.lineWidth = max(1, CGFloat(size) / 256)
    highlight.stroke()

    // Symbol rendered white, centred at ~58% of canvas
    let pt = CGFloat(size) * 0.58
    let config = NSImage.SymbolConfiguration(pointSize: pt, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let sz = symbol.size
        let rect = NSRect(
            x: (CGFloat(size) - sz.width) / 2,
            y: (CGFloat(size) - sz.height) / 2,
            width: sz.width,
            height: sz.height
        )
        // Template-tint the symbol to white via an offscreen draw.
        let tinted = NSImage(size: sz, flipped: false) { bounds in
            symbol.draw(in: bounds)
            NSColor.white.set()
            bounds.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: rect)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for target in targets {
    guard let png = renderIcon(size: target.size) else {
        fputs("render failed for \(target.name)\n", stderr)
        exit(2)
    }
    let out = outputDir.appendingPathComponent(target.name)
    try png.write(to: out)
}
print("wrote \(targets.count) PNGs using symbol '\(symbolName)' → \(outputDir.path)")
