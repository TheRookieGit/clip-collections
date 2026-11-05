import Foundation

public struct CaptureError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The clean page handed to the renderer. `bodyHTML` came from the web, so it is rendered with scripts off and with a
/// policy that only allows local files.
struct CleanDocument {
    var title: String
    var source: String
    var publishedAt: String
    var link: String
    var savedAt: Date
    var bodyHTML: String
}

func escapeHTML(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}

enum Page {
    /// One template for every source: A4 margins come from the print settings; the CSS keeps a picture whole and
    /// shrinks one taller than a page to fit it (the height is the printable height in CSS pixels).
    static func html(_ d: CleanDocument) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        let meta = [("来源", d.source), ("发布", d.publishedAt), ("保存", f.string(from: d.savedAt))]
            .filter { !$0.1.isEmpty }.map { "<span><b>\($0.0)</b> \(escapeHTML($0.1))</span>" }.joined()
        return #"""
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src file: data:; style-src 'unsafe-inline'; font-src file:">
        <title>\#(escapeHTML(d.title))</title>
        <style>
        html,body{margin:0;padding:0;background:#fff;color:#1c1c1e}
        body{font:12pt/1.75 -apple-system,"PingFang SC","Hiragino Sans GB","Songti SC",sans-serif;word-break:break-word;overflow-wrap:anywhere}
        header{border-bottom:1px solid #c7c7cc;padding-bottom:10pt;margin-bottom:16pt}
        h1.clip-title{font-size:20pt;line-height:1.35;margin:0 0 8pt;font-weight:600}
        .clip-meta{font-size:9.5pt;line-height:1.6;color:#636366}
        .clip-meta span{margin-right:14pt;display:inline-block}.clip-meta b{font-weight:500;color:#3a3a3c}
        .clip-link{font-size:9pt;color:#636366;word-break:break-all;margin-top:2pt}
        h1,h2,h3,h4{line-height:1.4;break-after:avoid;page-break-after:avoid}
        p{margin:0 0 .9em;orphans:2;widows:2}
        figure{margin:12pt 0;break-inside:avoid;page-break-inside:avoid}
        figcaption{font-size:9.5pt;color:#636366;text-align:center}
        img{display:block;max-width:100%;max-height:\#(printableCSSHeight)px;width:auto;height:auto;margin:10pt auto;break-inside:avoid;page-break-inside:avoid}
        pre{white-space:pre-wrap;font-size:10pt;background:#f2f2f7;padding:8pt}
        table{border-collapse:collapse;max-width:100%}td,th{border:1px solid #d1d1d6;padding:3pt 6pt}
        blockquote{margin:0 0 .9em;padding-left:10pt;border-left:2pt solid #d1d1d6;color:#3a3a3c}
        a{color:inherit;text-decoration:none}
        .clip-note{white-space:pre-wrap}
        .clip-notice{font-size:10pt;background:#f2f2f7;padding:6pt 8pt;margin-bottom:12pt}
        </style></head><body>
        <header><h1 class="clip-title">\#(escapeHTML(d.title))</h1><div class="clip-meta">\#(meta)</div>
        <div class="clip-link">\#(escapeHTML(d.link))</div></header>
        <main>\#(d.bodyHTML)</main></body></html>
        """#
    }

    /// A little under the printable height of an A4 page in CSS pixels: WebKit cuts anything taller than a page, ignoring break-inside.
    static let printableCSSHeight = 880

    static func xhsBody(_ note: XHSNote, images: [String?]) -> String {
        var html = ""
        if note.isVideo { html += #"<div class="clip-notice">这是一条视频笔记：这里保留封面和文字，视频本身没有保存。</div>"# }
        html += "<div class=\"clip-note\">\(escapeHTML(note.body))</div>"
        for file in images.compactMap({ $0 }) { html += "<img src=\"\(escapeHTML(file))\" alt=\"\">" }
        return html
    }
}
