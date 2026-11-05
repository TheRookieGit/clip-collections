// Draws the icon: a vermilion seal with 拾 in it.
//   swift scripts/make-icon.swift <folder>         the Mac app's .iconset, with the margin and corners macOS expects
//   swift scripts/make-icon.swift --web <folder>   the web page's icons: full bleed, since iOS rounds the corners itself
import AppKit
import CoreText

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func glyph(_ c: String, size: CGFloat, color: NSColor, center: NSPoint) {
    // Centred on the ink of the character, not on its line box.
    let font = NSFont(name: "STSongti-SC-Black", size: size) ?? .boldSystemFont(ofSize: size)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: c, attributes: [.font: font, .foregroundColor: color]))
    let box = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.textPosition = CGPoint(x: center.x - box.midX, y: center.y - box.midY)
    CTLineDraw(line, ctx)
}

func draw(in rect: NSRect, bleed: Bool = false) {
    let tile = bleed ? rect : rect.insetBy(dx: rect.width * 0.1, dy: rect.height * 0.1)
    let s = tile.width
    let cream = rgb(0xF7F0E2)
    rgb(0xB23A2A).setFill()
    (bleed ? NSBezierPath(rect: tile) : NSBezierPath(roundedRect: tile, xRadius: s * 0.225, yRadius: s * 0.225)).fill()
    // The inner line of a seal.
    let frame = NSBezierPath(roundedRect: tile.insetBy(dx: s * 0.1, dy: s * 0.1), xRadius: s * 0.03, yRadius: s * 0.03)
    frame.lineWidth = max(1, s * 0.022)
    cream.setStroke()
    frame.stroke()
    glyph("拾", size: s * 0.58, color: cream, center: NSPoint(x: tile.midX, y: tile.midY))
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
