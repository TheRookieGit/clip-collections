// Draws the icon: a paper clip on vermilion.
//   swift scripts/make-icon.swift <folder>         the Mac app's .iconset, with the margin and corners macOS expects
//   swift scripts/make-icon.swift --web <folder>   the web page's icons: full bleed, since iOS rounds the corners itself
import AppKit

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

/// A paper clip, drawn as one line from the short inner end round to the long outer end.
func clip(in tile: NSRect) {
    let s = tile.width, cx = tile.midX, cy = tile.midY, u = s * 0.082
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: cx, yBy: cy); t.rotate(byDegrees: -38); t.translateX(by: -cx, yBy: -cy)
    t.concat()
    let p = NSBezierPath()
    p.lineWidth = s * 0.052
    p.lineCapStyle = .round
    p.lineJoinStyle = .round
    let outerL = cx - u * 1.5, outerR = cx + u * 1.5, innerL = cx - u * 0.6, innerR = cx + u * 0.6
    p.move(to: NSPoint(x: innerR, y: cy + u * 2.6))
    p.line(to: NSPoint(x: innerR, y: cy - u * 3.2))
    p.appendArc(from: NSPoint(x: innerR, y: cy - u * 4.4), to: NSPoint(x: cx, y: cy - u * 4.4), radius: u * 0.6)
    p.appendArc(from: NSPoint(x: innerL, y: cy - u * 4.4), to: NSPoint(x: innerL, y: cy - u * 3.2), radius: u * 0.6)
    p.line(to: NSPoint(x: innerL, y: cy + u * 3.4))
    p.appendArc(from: NSPoint(x: innerL, y: cy + u * 4.8), to: NSPoint(x: cx + u * 0.3, y: cy + u * 4.8), radius: u * 0.9)
    p.appendArc(from: NSPoint(x: outerR, y: cy + u * 4.8), to: NSPoint(x: outerR, y: cy + u * 3.4), radius: u * 1.05)
    p.line(to: NSPoint(x: outerR, y: cy - u * 3.6))
    p.appendArc(from: NSPoint(x: outerR, y: cy - u * 5.6), to: NSPoint(x: cx, y: cy - u * 5.6), radius: u * 1.5)
    p.appendArc(from: NSPoint(x: outerL, y: cy - u * 5.6), to: NSPoint(x: outerL, y: cy - u * 3.6), radius: u * 1.5)
    p.line(to: NSPoint(x: outerL, y: cy + u * 1.8))
    rgb(0xF7F0E2).setStroke()
    p.stroke()
    NSGraphicsContext.restoreGraphicsState()
}

func draw(in rect: NSRect, bleed: Bool = false) {
    let tile = bleed ? rect : rect.insetBy(dx: rect.width * 0.1, dy: rect.height * 0.1)
    let s = tile.width
    rgb(0xB23A2A).setFill()
    (bleed ? NSBezierPath(rect: tile) : NSBezierPath(roundedRect: tile, xRadius: s * 0.225, yRadius: s * 0.225)).fill()
    clip(in: tile)
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
