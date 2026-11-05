// Draws the icon (a vermilion seal on a sheet of newsprint).
//   swift scripts/make-icon.swift <folder>         the Mac app's .iconset, with the margin and corners macOS expects
//   swift scripts/make-icon.swift --web <folder>   the web page's icons: full bleed, since iOS rounds the corners itself
import AppKit

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func draw(in rect: NSRect, bleed: Bool = false) {
    let tile = bleed ? rect : rect.insetBy(dx: rect.width * 0.1, dy: rect.height * 0.1)
    let s = tile.width
    let path = bleed ? NSBezierPath(rect: tile) : NSBezierPath(roundedRect: tile, xRadius: s * 0.225, yRadius: s * 0.225)
    rgb(0xF4EEE1).setFill()
    path.fill()
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    // Column rules of a printed page, faint behind the seal.
    rgb(0x201C17).setFill()
    NSBezierPath(rect: NSRect(x: tile.minX + s * 0.14, y: tile.maxY - s * 0.2, width: s * 0.72, height: max(1, s * 0.022))).fill()
    NSBezierPath(rect: NSRect(x: tile.minX + s * 0.14, y: tile.maxY - s * 0.235, width: s * 0.72, height: max(1, s * 0.007))).fill()
    rgb(0xB9B0A0).setFill()
    for i in 0..<3 {
        NSBezierPath(rect: NSRect(x: tile.minX + s * 0.14, y: tile.minY + s * (0.1 + CGFloat(i) * 0.055), width: s * (i == 0 ? 0.42 : 0.72), height: max(1, s * 0.012))).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    // The seal.
    let side = s * 0.5
    let seal = NSRect(x: tile.midX - side / 2, y: tile.midY - side * 0.5 + s * 0.015, width: side, height: side)
    let t = NSAffineTransform()
    t.translateX(by: seal.midX, yBy: seal.midY); t.rotate(byDegrees: -3); t.translateX(by: -seal.midX, yBy: -seal.midY)
    NSGraphicsContext.saveGraphicsState()
    t.concat()
    rgb(0xB23A2A).setFill()
    NSBezierPath(roundedRect: seal, xRadius: s * 0.03, yRadius: s * 0.03).fill()
    let text = NSAttributedString(string: "拾", attributes: [.font: NSFont(name: "STSongti-SC-Black", size: side * 0.72) ?? .boldSystemFont(ofSize: side * 0.72), .foregroundColor: rgb(0xF9F4E8)])
    let size = text.size()
    text.draw(at: NSPoint(x: seal.midX - size.width / 2, y: seal.midY - size.height / 2))
    NSGraphicsContext.restoreGraphicsState()
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
