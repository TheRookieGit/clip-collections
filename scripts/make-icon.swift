// Draws the app icon (a clipped page on a deep ink tile) into an .iconset folder: swift scripts/make-icon.swift <folder>
import AppKit

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func draw(in rect: NSRect) {
    let tile = rect.insetBy(dx: rect.width * 0.1, dy: rect.height * 0.1)
    let s = tile.width
    let path = NSBezierPath(roundedRect: tile, xRadius: s * 0.225, yRadius: s * 0.225)
    NSGradient(colors: [rgb(0x2F4A5C), rgb(0x1E3442)])!.draw(in: path, angle: -90)
    let page = NSRect(x: tile.minX + s * 0.25, y: tile.minY + s * 0.17, width: s * 0.5, height: s * 0.66)
    rgb(0xF7F3E8).setFill()
    NSBezierPath(roundedRect: page, xRadius: s * 0.025, yRadius: s * 0.025).fill()
    rgb(0xB0452C).setFill()
    NSBezierPath(rect: NSRect(x: page.minX + s * 0.06, y: page.maxY - s * 0.17, width: s * 0.38, height: s * 0.06)).fill()
    rgb(0x8C8778).setFill()
    for i in 0..<4 {
        let w = i == 3 ? s * 0.22 : s * 0.38
        NSBezierPath(rect: NSRect(x: page.minX + s * 0.06, y: page.maxY - s * (0.27 + CGFloat(i) * 0.085), width: w, height: s * 0.028)).fill()
    }
}

let folder = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
for (name, size) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.current = nil
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(folder)/icon_\(name).png"))
}
