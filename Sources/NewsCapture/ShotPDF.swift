import AppKit
import CoreText
import ImageIO

/// Screenshots of one news item as one A4 PDF. Every picture fills the page width, so its words stay the size they
/// were; a screenshot longer than a page runs on across pages instead of shrinking.
public enum ShotPDF {
    static let page = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
    static let margin: CGFloat = 28

    public struct Meta {
        public var title: String, source: String, publishedAt: String, link: String, savedAt: Date
        public init(title: String, source: String, publishedAt: String, link: String, savedAt: Date) {
            self.title = title; self.source = source; self.publishedAt = publishedAt; self.link = link; self.savedAt = savedAt
        }
    }

    /// Horizontal cuts (in image pixels) for an image `height` tall showing `pageRows` pixels per page, preferring a
    /// row of one colour within the last 12% of a page so a line of text is not cut in half.
    static func cuts(height: Int, pageRows: Int, firstRows: Int, plainRow: (Int) -> Bool) -> [Range<Int>] {
        var out: [Range<Int>] = [], y = 0, rows = firstRows
        while y < height {
            var end = min(y + rows, height)
            if end < height {
                let floor = end - rows / 8
                var r = end
                while r > floor { if plainRow(r) { end = r; break }; r -= 1 }
            }
            out.append(y..<end)
            y = end
            rows = pageRows
        }
        return out
    }

    public static func build(images: [URL], meta: Meta, to out: URL) throws -> Int {
        var box = page
        guard let ctx = CGContext(out as CFURL, mediaBox: &box, [kCGPDFContextTitle as String: meta.title] as CFDictionary) else { throw CaptureError("PDF 生成失败") }
        let width = page.width - margin * 2, fullHeight = page.height - margin * 2
        var pageOpen = false, cursor: CGFloat = 0, drawn = 0

        func newPage() { if pageOpen { ctx.endPDFPage() }; ctx.beginPDFPage(nil); pageOpen = true; cursor = page.height - margin }
        newPage()
        cursor = drawHeader(ctx, meta, top: cursor, width: width)

        for url in images {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: true] as CFDictionary) else { continue }
            // EXIF rotation is applied so a phone photo stands upright.
            let upright = rotated(cg, source: src)
            let scale = width / CGFloat(upright.width)
            let tall = CGFloat(upright.height) * scale
            if tall <= fullHeight && tall > cursor - margin { newPage() }
            if tall > fullHeight && cursor - margin < fullHeight * 0.2 { newPage() }
            let rowsPerPage = Int(fullHeight / scale)
            let firstRows = max(1, Int((cursor - margin) / scale))
            let rows = plainRows(upright)
            for part in cuts(height: upright.height, pageRows: rowsPerPage, firstRows: tall <= fullHeight ? upright.height : firstRows, plainRow: { rows[safe: $0] ?? false }) {
                guard let slice = upright.cropping(to: CGRect(x: 0, y: part.lowerBound, width: upright.width, height: part.count)) else { continue }
                let h = CGFloat(part.count) * scale
                if cursor - h < margin - 0.5 { newPage() }
                ctx.draw(slice, in: CGRect(x: margin, y: cursor - h, width: width, height: h))
                cursor -= h
            }
            cursor -= 10
            drawn += 1
        }
        if pageOpen { ctx.endPDFPage() }
        ctx.closePDF()
        guard drawn == images.count else { throw CaptureError("有 \(images.count - drawn) 张截图打不开") }
        return drawn
    }

    private static func rotated(_ cg: CGImage, source: CGImageSource) -> CGImage {
        let side = max(cg.width, cg.height)
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: side]
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        guard let o = props?[kCGImagePropertyOrientation] as? Int, o != 1,
              let t = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return cg }
        return t
    }

    /// Whether each row is nearly one colour, read from a copy a few pixels wide.
    private static func plainRows(_ cg: CGImage) -> [Bool] {
        let w = 64, h = cg.height
        guard h < 200_000, let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                             bitmapInfo: CGImageAlphaInfo.none.rawValue), let d = { c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h)); return c.data }() else { return [] }
        let p = d.assumingMemoryBound(to: UInt8.self)
        return (0..<h).map { y in
            let row = p + y * w
            var lo: UInt8 = 255, hi: UInt8 = 0
            for x in 0..<w { lo = min(lo, row[x]); hi = max(hi, row[x]) }
            return hi - lo < 10
        }
    }

    private static func drawHeader(_ ctx: CGContext, _ m: Meta, top: CGFloat, width: CGFloat) -> CGFloat {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"
        let line = [m.source.isEmpty ? nil : "来源 \(m.source)", m.publishedAt.isEmpty ? nil : "发布 \(m.publishedAt)", "保存 \(df.string(from: m.savedAt))"].compactMap { $0 }.joined(separator: "    ")
        let text = NSMutableAttributedString(string: m.title + "\n", attributes: [.font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor.black])
        text.append(NSAttributedString(string: line + (m.link.isEmpty ? "" : "\n\(m.link)") + "\n", attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.darkGray]))
        let frameSetter = CTFramesetterCreateWithAttributedString(text)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(frameSetter, CFRange(), nil, CGSize(width: width, height: 300), nil)
        let rect = CGRect(x: margin, y: top - size.height, width: width, height: size.height)
        CTFrameDraw(CTFramesetterCreateFrame(frameSetter, CFRange(), CGPath(rect: rect, transform: nil), nil), ctx)
        return top - size.height - 12
    }
}

private extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }
