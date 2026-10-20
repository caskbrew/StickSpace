// Renders the monochrome menu bar glyph (three bars of decreasing length) as 1x/2x PNGs.
import AppKit
let out = CommandLine.arguments[1]
for scale in [1, 2] {
    let px = 18 * scale
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.black.setFill()
    let s = CGFloat(scale)
    // bar widths 14 / 11 / 8 (pt), height 3.4, gap 2.4, left aligned at x = 2
    let widths: [CGFloat] = [14, 11, 8]
    let h: CGFloat = 3.4, gap: CGFloat = 2.4
    let total = h * 3 + gap * 2
    var y = (18 - total) / 2 + (h + gap) * 2
    for w in widths {
        NSBezierPath(roundedRect: NSRect(x: 2 * s, y: y * s, width: w * s, height: h * s), xRadius: h * s / 2, yRadius: h * s / 2).fill()
        y -= h + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/menubar_\(scale)x.png"))
}
