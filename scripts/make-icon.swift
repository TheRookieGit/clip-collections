// Draws the icon: a folded newspaper page on vermilion.
//   swift scripts/make-icon.swift <folder>         the Mac app's .iconset, with the margin and corners macOS expects
//   swift scripts/make-icon.swift --web <folder>   the web page's icons: full bleed, since iOS rounds the corners itself
import AppKit

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: NSColor) {
    c.setFill()
    NSBezierPath(rect: NSRect(x: x, y: y, width: w, height: h)).fill()
}

/// A newspaper page with one corner folded: a headline in vermilion over two columns of text.
func newspaper(in tile: NSRect) {
    let s = tile.width, seal = rgb(0xB23A2A), ink = rgb(0x221E18)
    let p = NSRect(x: tile.midX - s * 0.28, y: tile.midY - s * 0.35, width: s * 0.56, height: s * 0.7)
    let fold = s * 0.15
    let sheet = NSBezierPath()
    sheet.move(to: NSPoint(x: p.minX, y: p.minY))
    sheet.line(to: NSPoint(x: p.maxX, y: p.minY))
    sheet.line(to: NSPoint(x: p.maxX, y: p.maxY - fold))
    sheet.line(to: NSPoint(x: p.maxX - fold, y: p.maxY))
    sheet.line(to: NSPoint(x: p.minX, y: p.maxY))
    sheet.close()
    rgb(0xF7F0E2).setFill()
    sheet.fill()
    let corner = NSBezierPath()
    corner.move(to: NSPoint(x: p.maxX - fold, y: p.maxY))
    corner.line(to: NSPoint(x: p.maxX - fold, y: p.maxY - fold))
    corner.line(to: NSPoint(x: p.maxX, y: p.maxY - fold))
    corner.close()
    rgb(0xC9BFAC).setFill()
    corner.fill()
    let m = s * 0.07, w = p.width - m * 2, gap = s * 0.04, col = (w - gap) / 2
    bar(p.minX + m, p.maxY - s * 0.2, w - s * 0.1, s * 0.05, seal)
    for c in 0..<2 {
        for i in 0..<4 {
            bar(p.minX + m + CGFloat(c) * (col + gap), p.minY + m + CGFloat(i) * s * 0.07, i == 0 && c == 1 ? col * 0.6 : col, s * 0.03, ink)
        }
    }
}

func draw(in rect: NSRect, bleed: Bool = false) {
    let tile = bleed ? rect : rect.insetBy(dx: rect.width * 0.1, dy: rect.height * 0.1)
    let s = tile.width
    rgb(0xB23A2A).setFill()
    (bleed ? NSBezierPath(rect: tile) : NSBezierPath(roundedRect: tile, xRadius: s * 0.225, yRadius: s * 0.225)).fill()
    newspaper(in: tile)
}

func write(_ file: String, size: Int, bleed: Bool = false) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(in: NSRect(x: 0, y: 0, width: size, height: size), bleed: bleed)
    NSGraphicsContext.current = nil
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: file))
}

let web = CommandLine.arguments[1] == "--web"
let folder = CommandLine.arguments[web ? 2 : 1]
try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
if web {
    try write("\(folder)/apple-touch-icon.png", size: 180, bleed: true)
    try write("\(folder)/favicon.png", size: 64, bleed: true)
} else {
    for (name, size) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
        try write("\(folder)/icon_\(name).png", size: size)
    }
}
