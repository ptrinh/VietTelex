// make_icon.swift — generate the menu-bar badge as a VECTOR PDF (MenuIcon.pdf),
// the format the system actually expects for input-method icons: Squirrel/RIME
// ships a single PDF (media box 22×16 pt) referenced by all three icon keys,
// and it renders crisp at every DPI and correctly in dark mode. Bitmap TIFFs
// with mismatched point sizes were the cause of the blurry/small/misaligned
// renders we went through.
//
// Design: SQUARE OUTLINE box (stroked border, transparent inside) filling a
// square canvas — matches the height of the system "US" badge, and since the
// menu icon slot is square, a square canvas maps 1:1 (no distortion). Solid "VT"
// inside (T = V/φ, shared baseline), auto-sized to fill both axes. Single black
// vector; the system handles dark-mode tinting.
//
// Why square (not golden-ratio): the input-source slot stretches the icon to a
// square with independent-axis scaling, so a wide box would be squished. Square
// canvas + square box = full height like "US", undistorted. (Chosen over a
// letterboxed golden box, which stays undistorted but renders shorter than "US".)
//
// Usage: swift make_icon.swift <resourcesDir>     → writes MenuIcon.pdf
// (The APP icon comes from assets/VietTelex-logo.png via Scripts/make_appicon.py.)

import AppKit
import CoreText

let phi: CGFloat = (1 + 5.0.squareRoot()) / 2

/// Outline path of one character at `size`, translated so its glyph bounding
/// box starts at `origin` (x) and sits on baseline `origin.y`.
func glyphPath(_ ch: Character, weight: NSFont.Weight, size: CGFloat,
               baselineY: CGFloat, leftX: CGFloat) -> (path: CGPath, width: CGFloat)? {
    let font = NSFont.systemFont(ofSize: size, weight: weight) as CTFont
    var chars = [UniChar](String(ch).utf16)
    var glyph = CGGlyph()
    guard CTFontGetGlyphsForCharacters(font, &chars, &glyph, 1) else { return nil }
    var bbox = CGRect.zero
    withUnsafeMutablePointer(to: &glyph) { g in
        bbox = CTFontGetBoundingRectsForGlyphs(font, .default, g, nil, 1)
    }
    var transform = CGAffineTransform(translationX: leftX - bbox.minX, y: baselineY)
    guard let path = CTFontCreatePathForGlyph(font, glyph, &transform) else { return nil }
    return (path, bbox.width)
}

let args = CommandLine.arguments
guard args.count >= 2 else { fputs("usage: make_icon.swift <resourcesDir>\n", stderr); exit(1) }
let outURL = URL(fileURLWithPath: args[1]).appendingPathComponent("MenuIcon.pdf")

// SQUARE media box. macOS stretches the input-source menu icon to a SQUARE
// (independent-axis scale), so a wide media box gets squished to square. We make
// the canvas square — the stretch is then a 1:1 no-op — and letterbox the
// golden-ratio box inside it (transparent margins top/bottom). The box keeps its
// true φ proportions and is never distorted. Trade-off dictated by the OS: a wide
// box can only be ~1/φ of the square's height, so it sits shorter than a
// full-height square badge (that shorter-but-undistorted is the point).
let S: CGFloat = 16                                   // square canvas (menu-icon standard)
var mediaBox = CGRect(x: 0, y: 0, width: S, height: S)
guard let ctx = CGContext(outURL as CFURL, mediaBox: &mediaBox, nil) else {
    fputs("cannot create PDF context\n", stderr); exit(1)
}
ctx.beginPDFPage(nil)

// Square box, near-full-bleed (border flush to the square canvas edges).
let borderWidth: CGFloat = 1.0
let box = CGRect(x: borderWidth / 2, y: borderWidth / 2,
                 width: S - borderWidth, height: S - borderWidth)
let radius = box.height * 0.28                        // like the system "A" badge

// "V" is the dominant glyph, sized like the system "A" letter (~66% of the box
// cap height). "T" is a small subscript tucked tight against the V so the pair
// fits the square. Size by MEASURED cap height (SF cap height is only ~72% of
// point size, so font size ≠ visible height).
let probeSize: CGFloat = 20
guard let vProbe = glyphPath("V", weight: .bold, size: probeSize, baselineY: 0, leftX: 0)
else { fputs("glyph path failed\n", stderr); exit(1) }
let capPerPt = vProbe.path.boundingBox.height / probeSize          // cap height per point
let vSize = S * 0.53 / capPerPt                                    // V cap = 0.53×(outer box), = the system "A" (17px @ 32px box)
let tSize = vSize * 0.4                                            // T = 0.4×V, small
let gap = -vSize * 0.05                                            // neo theo V; nhẹ tay hơn

// Final glyph widths, to center the VT pair horizontally.
guard let vW = glyphPath("V", weight: .bold, size: vSize, baselineY: 0, leftX: 0),
      let tW = glyphPath("T", weight: .black, size: tSize, baselineY: 0, leftX: 0)
else { fputs("glyph path failed\n", stderr); exit(1) }
let totalW = vW.width + gap + tW.width
let capV = vW.path.boundingBox.height
let baselineY = box.minY + (box.height - capV) / 2
let leftX = box.minX + (box.width - totalW) / 2

guard let v = glyphPath("V", weight: .bold, size: vSize, baselineY: baselineY, leftX: leftX),
      let t = glyphPath("T", weight: .black, size: tSize, baselineY: baselineY,
                        leftX: leftX + v.width + gap)
else { fputs("glyph path failed\n", stderr); exit(1) }

// Stroked border (crisp vector outline, transparent inside)…
ctx.setStrokeColor(CGColor.black)
ctx.setLineWidth(borderWidth)
ctx.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.strokePath()

// …and solid VT glyphs inside.
let glyphs = CGMutablePath()
glyphs.addPath(v.path)
glyphs.addPath(t.path)
ctx.setFillColor(CGColor.black)
ctx.addPath(glyphs)
ctx.fillPath()

// Thicken the small T with an extra outline stroke — the system's heaviest
// weight (.black) plus this reads ~2 steps bolder than the V (.bold), which the
// tiny subscript needs to hold weight against the big V.
ctx.setStrokeColor(CGColor.black)
ctx.setLineWidth(tSize * 0.06)
ctx.setLineJoin(.round)
ctx.addPath(t.path)
ctx.strokePath()

ctx.endPDFPage()
ctx.closePDF()
print("MenuIcon.pdf written (16x16 pt vector)")
