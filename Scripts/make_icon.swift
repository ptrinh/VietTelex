// make_icon.swift — generate a simple "V" app icon set + a template menu icon.
// Usage: swift make_icon.swift <iconsetDir> <menuIconTiffPath>
// Draws headlessly via NSBitmapImageRep (no window/display needed).

import AppKit
import Foundation

func drawV(size: Int, template: Bool) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size)
    let rect = NSRect(x: 0, y: 0, width: s, height: s)

    if !template {
        let inset = s * 0.06
        let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        let path = NSBezierPath(roundedRect: body, xRadius: s * 0.22, yRadius: s * 0.22)
        let grad = NSGradient(colors: [NSColor(calibratedRed: 0.83, green: 0.16, blue: 0.16, alpha: 1),
                                       NSColor(calibratedRed: 0.60, green: 0.05, blue: 0.05, alpha: 1)])!
        grad.draw(in: path, angle: -90)
    }

    let glyphColor: NSColor = template ? .black : .white
    drawCenteredV(in: rect, size: s, color: glyphColor)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// Grey rounded box + white centered "V" — the menu-bar / input-source badge.
func drawBadge(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size)
    let inset = s * 0.04
    let box = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    NSColor(calibratedRed: 0.56, green: 0.56, blue: 0.58, alpha: 1).setFill()
    NSBezierPath(roundedRect: box, xRadius: s * 0.2, yRadius: s * 0.2).fill()
    drawCenteredV(in: NSRect(x: 0, y: 0, width: s, height: s), size: s, color: .white)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// Draw a bold "V" centered both axes in `rect` (proper glyph-bounds centering).
func drawCenteredV(in rect: NSRect, size s: CGFloat, color: NSColor) {
    let para = NSMutableParagraphStyle(); para.alignment = .center
    let font = NSFont.systemFont(ofSize: s * 0.6, weight: .bold)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
    let str = NSAttributedString(string: "V", attributes: attrs)
    let bb = str.boundingRect(with: NSSize(width: s, height: s), options: [.usesLineFragmentOrigin])
    let drawRect = NSRect(x: 0, y: (s - bb.height) / 2, width: s, height: bb.height)
    str.draw(with: drawRect, options: [.usesLineFragmentOrigin])
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) {
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: url)
}

let args = CommandLine.arguments
guard args.count >= 3 else { fputs("usage: make_icon.swift <iconsetDir> <menuTiff>\n", stderr); exit(1) }
let iconsetDir = URL(fileURLWithPath: args[1])
let menuTiff = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

// Standard iconset entries.
let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in entries {
    writePNG(drawV(size: px, template: false), to: iconsetDir.appendingPathComponent("\(name).png"))
}

// Menu / input-source badge: grey rounded box + white centered V.
// Multi-resolution TIFF (18 @1x, 36 @2x) so it's crisp in the menu bar & picker.
let rep1x = drawBadge(size: 18)
let rep2x = drawBadge(size: 36)
let tiff = NSBitmapImageRep.representationOfImageReps(in: [rep1x, rep2x],
                                                      using: .tiff, properties: [:])!
try! tiff.write(to: menuTiff)
print("icons written")
