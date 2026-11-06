import AppKit
import ImageIO
import PDFKit
import WebKit

public enum CaptureStatus: String { case saved, incomplete, failed }

/// What one capture produced, including what could be checked about the file itself.
public struct CaptureResult {
    public var requested: String
    public var finalURL = ""
    public var kind = "article"              // xhs / article
    public var mode = "clean"                // clean / fullpage (the fallback, shown to the user)
    public var status = CaptureStatus.failed
    public var reason = ""
    public var title = ""
    public var source = ""
    public var publishedAt = ""
    public var isVideo = false
    public var textLength = 0
    public var excerpt = ""                  // the start of the text, for Claude to name a topic from
    public var expectedImages: Int?          // the note's own count (Xiaohongshu) or images found in the article
    public var downloadedImages = 0
    public var renderedImages = 0            // decoded by the renderer
    public var pdfImages = 0                 // images found in the finished PDF that match a downloaded picture by size
    public var repeatedImages = 0            // byte-identical pictures in the note, which the PDF stores only once
    public var pdfPages = 0
    public var pdf: URL?
    public var failures: [String] = []
}

/// Loads a page in a hidden WKWebView and turns it into a PDF. The persistent data store is what keeps site logins
/// from the login window.
@MainActor
public final class Capturer: NSObject, WKNavigationDelegate {
    public static let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    public static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    /// Fixed, so the login window and every capture share one set of cookies.
    public static let store = WKWebsiteDataStore(forIdentifier: UUID(uuidString: "6C1F5B7E-3A4D-4E0B-9C55-71C2D3A8F001")!)

    private let readabilityJS: String
    private var loadDone: CheckedContinuation<Void, Error>?
    private var blocked: Error?
    private var loadToken = 0
    /// The one local folder the renderer may read while a clean page is being laid out.
    private var renderDir: URL?

    public init(readabilityJS: String = "") { self.readabilityJS = readabilityJS }

    /// The Readability bundled with the app. Falls back to the repository copy for the command-line probe.
    public static func bundledReadability() -> String? {
        let name = "Readability-0.6.0"
        let url = Bundle.main.url(forResource: name, withExtension: "js")
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/vendor/\(name).js")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    public static func makeWebView(userAgent: String, frame: NSRect = NSRect(x: 0, y: 0, width: 1200, height: 900)) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        config.preferences.isElementFullscreenEnabled = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: frame, configuration: config)
        view.customUserAgent = userAgent
        return view
    }

    // MARK: Navigation

    public func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard a.targetFrame?.isMainFrame == true, let url = a.request.url else { return .allow }
        if url.scheme == "about" { return .allow }
        if url.isFileURL {
            guard let renderDir, url.standardizedFileURL.path.hasPrefix(renderDir.standardizedFileURL.path + "/") else { return .cancel }
            return .allow
        }
        do { try await Task.detached { try URLGuard.checkResolved(url) }.value; return .allow }
        catch { blocked = error; return .cancel }
    }
    public func webView(_ w: WKWebView, didFinish n: WKNavigation!) { finish(nil) }
    public func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { finish(e) }
    public func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { finish(blocked ?? e) }
    public func webViewWebContentProcessDidTerminate(_ w: WKWebView) { finish(CaptureError("网页进程崩溃")) }

    private func finish(_ e: Error?) {
        guard let c = loadDone else { return }
        loadDone = nil
        if let e, (e as NSError).code != NSURLErrorCancelled || blocked != nil { c.resume(throwing: e) } else { c.resume() }
    }

    private func load(_ view: WKWebView, _ url: URL, timeout: TimeInterval = 40) async throws {
        try await waitForLoad(view, timeout: timeout + 5) { view.load(URLRequest(url: url, timeoutInterval: timeout)) }
    }

    private func waitForLoad(_ view: WKWebView, timeout: TimeInterval, start: () -> Void) async throws {
        view.navigationDelegate = self
        blocked = nil
        loadToken += 1
        let token = loadToken
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            loadDone = c
            start()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                if self?.loadToken == token { self?.finish(CaptureError("网页加载超时")) }
            }
        }
    }

    private func js(_ view: WKWebView, _ body: String, args: [String: Any] = [:], world: WKContentWorld) async throws -> Any? {
        try await view.callAsyncJavaScript(body, arguments: args, in: nil, contentWorld: world)
    }

    // MARK: Capture

    public func capture(_ link: String, workDir: URL, outFile: URL, savedAt: Date = Date()) async -> CaptureResult {
        var r = CaptureResult(requested: link)
        do {
            guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw CaptureError("链接无效") }
            try await Task.detached { try URLGuard.checkResolved(url) }.value
            try? FileManager.default.removeItem(at: workDir) // files left by an earlier try would pass the count check
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            guard !readabilityJS.isEmpty || XHS.isXHS(url) else { throw CaptureError("缺少正文提取组件") }
            if XHS.isXHS(url) { try await captureXHS(url, &r, workDir, outFile, savedAt) }
            else { try await captureArticle(url, &r, workDir, outFile, savedAt) }
        } catch {
            r.status = .failed
            r.reason = error.localizedDescription
        }
        return r
    }

    private func hidden(_ ua: String) -> (WKWebView, NSWindow) {
        let view = Self.makeWebView(userAgent: ua)
        // In a window that is never shown: without one WebKit throttles timers and lazy images never start.
        let w = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = view
        w.isReleasedWhenClosed = false
        w.alphaValue = 0
        w.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        w.orderBack(nil)
        return (view, w)
    }

    private func captureXHS(_ url: URL, _ r: inout CaptureResult, _ dir: URL, _ out: URL, _ savedAt: Date) async throws {
        r.kind = "xhs"
        var note: XHSNote?
        var usedUA = Self.desktopUA
        var referer = "https://www.xiaohongshu.com/"
        for ua in [Self.desktopUA, Self.mobileUA] {
            let (view, win) = hidden(ua)
            defer { win.orderOut(nil) }
            try await load(view, url)
            _ = try? await js(view, "await new Promise(r => setTimeout(r, 1800)); return true", world: .page)
            r.finalURL = view.url?.absoluteString ?? ""
            if let s = try? await js(view, XHS.extractJS, world: .page) as? String, let n = XHS.parse(json: s) {
                note = n; usedUA = ua; referer = r.finalURL
                break
            }
        }
        guard let note else {
            let f = r.finalURL
            if f.contains("/404/sec_") || f.contains("xhs_sec_server") { throw CaptureError("小红书暂时限制了这次访问：可以过一会儿重试，也可以登录网站后重试，或者改用截图") }
            if f.contains("/login") || f.contains("captcha") { throw CaptureError("小红书要求登录或验证：可以登录网站后重试，或者改用截图") }
            throw CaptureError("页面里没有找到笔记数据，笔记可能已删除或链接已失效")
        }
        r.title = note.title.isEmpty ? String(note.body.prefix(40)) : note.title
        r.source = note.author.isEmpty ? "小红书" : "小红书 · \(note.author)"
        r.isVideo = note.isVideo
        r.textLength = note.body.count
        r.excerpt = String((note.title + "\n" + note.body).prefix(3000))
        r.expectedImages = note.expected
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        r.publishedAt = note.publishedAt.map(df.string(from:)) ?? ""

        let cookies = await Self.store.httpCookieStore.allCookies()
        var files = [String?](repeating: nil, count: note.imageURLs.count)
        var failed: [Int: String] = [:]
        await withTaskGroup(of: (Int, Result<LocalImage, Error>).self) { g in
            for (i, u) in note.imageURLs.enumerated() {
                g.addTask {
                    guard !u.isEmpty else { return (i, .failure(CaptureError("没有图片地址"))) }
                    return (i, await ImageFetcher.fetch(u, referer: referer, userAgent: usedUA, cookies: cookies, to: dir, name: String(format: "img-%03d", i)))
                }
            }
            for await (i, res) in g {
                switch res {
                case .success(let img): files[i] = img.file.lastPathComponent
                case .failure(let e): failed[i] = "第 \(i + 1) 张：\(e.localizedDescription)"
                }
            }
        }
        r.failures = failed.sorted { $0.key < $1.key }.map(\.value)
        r.downloadedImages = files.compactMap { $0 }.count
        let doc = CleanDocument(title: r.title, source: r.source, publishedAt: r.publishedAt, link: r.finalURL.isEmpty ? r.requested : r.finalURL,
                                savedAt: savedAt, bodyHTML: Page.xhsBody(note, images: files))
        try await renderClean(doc, &r, dir, out)
        finishCheck(&r, what: "笔记")
    }

    private func captureArticle(_ url: URL, _ r: inout CaptureResult, _ dir: URL, _ out: URL, _ savedAt: Date) async throws {
        let (view, win) = hidden(Self.desktopUA)
        defer { win.orderOut(nil) }
        try await load(view, url)
        r.finalURL = view.url?.absoluteString ?? url.absoluteString
        _ = try? await js(view, Scripts.scroll, args: ["seconds": 25], world: .defaultClient)

        var why = ""
        let raw = try? await js(view, Scripts.readability(library: readabilityJS), world: .defaultClient) as? String
        let o = raw.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var content = o["content"] as? String ?? ""
        r.title = o["title"] as? String ?? view.title ?? ""
        r.source = o["site"] as? String ?? url.host ?? ""
        r.publishedAt = o["published"] as? String ?? ""
        r.textLength = o["textLength"] as? Int ?? 0
        r.excerpt = String((r.title + "\n" + (o["text"] as? String ?? "")).prefix(3000))
        let addresses = (o["images"] as? [String] ?? []).filter { $0.hasPrefix("http") }
        let unique = Array(NSOrderedSet(array: addresses)) as? [String] ?? addresses
        r.expectedImages = unique.count

        if content.isEmpty || r.textLength < 140 { why = "没有提取到正文" }
        else {
            let ua = Self.desktopUA, referer = r.finalURL
            let cookies = await Self.store.httpCookieStore.allCookies()
            var mapped: [String: String] = [:]
            await withTaskGroup(of: (String, Result<LocalImage, Error>).self) { g in
                for (i, u) in unique.enumerated() {
                    g.addTask { (u, await ImageFetcher.fetch(u, referer: referer, userAgent: ua, cookies: cookies, to: dir, name: String(format: "img-%03d", i))) }
                }
                for await (u, res) in g {
                    switch res {
                    case .success(let img): mapped[u] = img.file.lastPathComponent
                    case .failure(let e): r.failures.append("\(u.prefix(80))：\(e.localizedDescription)")
                    }
                }
            }
            r.downloadedImages = mapped.count
            if mapped.count < unique.count { why = "有 \(unique.count - mapped.count) 张图片下载失败" }
            for (u, name) in mapped {
                content = content.replacingOccurrences(of: "src=\"\(escapeHTML(u))\"", with: "src=\"\(name)\"")
                    .replacingOccurrences(of: "src=\"\(u)\"", with: "src=\"\(name)\"")
            }
        }
        if why.isEmpty {
            let doc = CleanDocument(title: r.title, source: r.source, publishedAt: r.publishedAt, link: r.finalURL, savedAt: savedAt, bodyHTML: content)
            try await renderClean(doc, &r, dir, out)
            if r.pdfImages + r.repeatedImages < unique.count { why = "PDF 里只有 \(r.pdfImages + r.repeatedImages)/\(unique.count) 张图片" }
        }
        if !why.isEmpty {
            // The fallback: the live page, printed as it stands.
            r.mode = "fullpage"
            r.reason = "\(why)，已退回整页打印"
            try await PDFPrinter.print(view, to: out, in: win)
            r.pdf = out
            inspect(&r, out)
        }
        r.status = r.pdf == nil ? .failed : .saved
    }

    private func renderClean(_ doc: CleanDocument, _ r: inout CaptureResult, _ dir: URL, _ out: URL) async throws {
        let page = dir.appendingPathComponent("page.html")
        try Page.html(doc).write(to: page, atomically: true, encoding: .utf8)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 794, height: 1123), configuration: config)
        let win = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = view
        win.isReleasedWhenClosed = false
        win.alphaValue = 0
        win.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        win.orderBack(nil)
        defer { win.orderOut(nil) }
        renderDir = dir
        defer { renderDir = nil }
        try await waitForLoad(view, timeout: 30) { view.loadFileURL(page, allowingReadAccessTo: dir) }
        // Scripts in the page are off; this one is the app's own. A picture the printer reaches before it is decoded
        // comes out as a blank space while still reporting a size, so every picture is decoded first.
        let decode = """
        const imgs = [...document.images];
        for (const i of imgs) { i.loading = 'eager'; i.decoding = 'sync'; }
        await Promise.allSettled(imgs.map(i => i.decode()));
        return imgs.filter(i => i.complete && i.naturalWidth > 0).length;
        """
        r.renderedImages = (try? await js(view, decode, world: .defaultClient)) as? Int ?? 0
        let (want, repeats) = PDFInspect.wanted(in: dir)
        r.repeatedImages = repeats
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
            try await PDFPrinter.print(view, to: out, in: win)
            r.pdf = out
            inspect(&r, out, want)
            if r.pdfImages >= PDFInspect.total(want) { break }
        }
    }

    /// Diagnostic: what a page exposes, for working out why a site failed. Prints structure, not page text.
    public func inspectPage(_ link: String) async -> String {
        guard let url = URL(string: link) else { return "bad url" }
        var lines: [String] = []
        for (label, ua) in [("desktop", Self.desktopUA), ("mobile", Self.mobileUA)] {
            let (view, win) = hidden(ua)
            defer { win.orderOut(nil) }
            do { try await load(view, url) } catch { lines.append("\(label): \(error.localizedDescription)"); continue }
            _ = try? await js(view, "await new Promise(r => setTimeout(r, 2000)); return true", world: .page)
            let s = try? await js(view, #"""
            const st = window.__INITIAL_STATE__;
            const feed = st && st.feed && st.feed.feeds;
            const list = feed && (feed._value || feed._rawValue || feed.value || feed);
            const links = Array.isArray(list) ? list.slice(0, 16).map(x => x && x.id && (`/explore/${x.id}?xsec_token=${x.xsecToken || x.xsec_token || ''}&xsec_source=pc_feed`)) : [];
            return JSON.stringify({ title: document.title, url: location.href, stateKeys: st ? Object.keys(st) : null, links, images: document.images.length, text: document.body.innerText.length });
            """#, world: .page) as? String
            lines.append("\(label): \(s ?? "nil")")
        }
        return lines.joined(separator: "\n")
    }

    /// Lays out a fixture with pictures of several shapes, one far taller than a page. Used by the self-test.
    public func renderFixture(dir: URL) async -> CaptureResult {
        var r = CaptureResult(requested: "fixture")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var body = "<div class=\"news-note\">" + String(repeating: "这是一段用来检查中文排版和分页的正文。", count: 60) + "</div>"
        for (i, (w, h)) in [(1080, 1440), (1080, 1440), (800, 6000), (1600, 900), (1080, 1440)].enumerated() {
            let name = "fix-\(i).png"
            let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
                NSColor(hue: CGFloat(i) / 5, saturation: 0.5, brightness: 0.8, alpha: 1).setFill(); rect.fill()
                NSColor.black.setStroke(); NSBezierPath(rect: rect.insetBy(dx: 10, dy: 10)).stroke()
                return true
            }
            if let t = img.tiffRepresentation, let b = NSBitmapImageRep(data: t), let png = b.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent(name))
            }
            body += "<img src=\"\(name)\" alt=\"\"><p>图 \(i + 1) 之后的文字。</p>"
        }
        let doc = CleanDocument(title: "分页测试：中文标题", source: "自测", publishedAt: "2026-11-04", link: "https://example.com/a", savedAt: Date(), bodyHTML: body)
        do { try await renderClean(doc, &r, dir, dir.appendingPathComponent("out.pdf")) } catch { r.reason = error.localizedDescription }
        return r
    }

    private func inspect(_ r: inout CaptureResult, _ out: URL, _ want: [PDFInspect.Size: Int]? = nil) {
        guard let d = CGPDFDocument(out as CFURL) else { return }
        r.pdfPages = d.numberOfPages
        r.pdfImages = want.map { PDFInspect.matched($0, in: d) } ?? PDFInspect.sizes(d).filter { $0.w >= 100 && $0.h >= 100 }.count
    }

    /// A note may only count as saved when every image of the note went through.
    private func finishCheck(_ r: inout CaptureResult, what: String) {
        guard r.pdf != nil else { r.status = .failed; return }
        let want = r.expectedImages ?? 0
        // Identical files share one object in the PDF, so repeats of a picture are counted back in.
        let inPDF = r.pdfImages + r.repeatedImages
        if inPDF < want {
            r.status = .incomplete
            r.reason = "图片不全：\(what)有 \(want) 张，PDF 里只有 \(inPDF) 张"
            let why = XHS.failureSummary(r.failures)
            if !why.isEmpty { r.reason += "（\(why)）" }
        } else { r.status = .saved }
        if r.isVideo { r.reason = [r.reason, "视频没有保存，只保留了封面和文字"].filter { !$0.isEmpty }.joined(separator: "；") }
    }
}

/// Checks the finished PDF, because a page that reports its pictures as loaded can still print them blank.
/// Pictures are told apart by pixel size, which also leaves out emoji and other small glyph bitmaps.
public enum PDFInspect {
    public struct Size: Hashable { public var w: Int; public var h: Int }

    /// The distinct downloaded pictures in `dir` as size -> count, and how many files were byte-identical repeats.
    static func wanted(in dir: URL) -> ([Size: Int], Int) {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var seen = Set<Data>(), out: [Size: Int] = [:], repeats = 0
        for f in files where f.lastPathComponent.hasPrefix("img-") || f.lastPathComponent.hasPrefix("fix-") {
            guard let data = try? Data(contentsOf: f) else { continue }
            guard seen.insert(data).inserted else { repeats += 1; continue }
            guard let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { continue }
            out[Size(w: w, h: h), default: 0] += 1
        }
        return (out, repeats)
    }

    static func total(_ want: [Size: Int]) -> Int { want.values.reduce(0, +) }

    /// How many wanted pictures are in the PDF. EXIF rotation can swap width and height.
    static func matched(_ want: [Size: Int], in doc: CGPDFDocument) -> Int {
        var have: [Size: Int] = [:]
        for s in sizes(doc) { have[s, default: 0] += 1 }
        var n = 0
        for (size, count) in want {
            var left = count
            for key in [size, Size(w: size.h, h: size.w)] {
                let take = min(left, have[key] ?? 0)
                left -= take; n += take
                have[key, default: 0] -= take
            }
        }
        return n
    }

    /// Pixel size of every image object on every page, including those inside form objects.
    public static func sizes(_ doc: CGPDFDocument) -> [Size] {
        var out: [Size] = []
        guard doc.numberOfPages > 0 else { return [] }
        for n in 1...doc.numberOfPages {
            guard let page = doc.page(at: n), let dict = page.dictionary else { continue }
            var res: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(dict, "Resources", &res), let res else { continue }
            collect(res, depth: 0, into: &out)
        }
        return out
    }

    private static func collect(_ resources: CGPDFDictionaryRef, depth: Int, into out: inout [Size]) {
        guard depth < 6 else { return }
        var xo: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xo), let xo else { return }
        final class Box { var sizes: [Size] = []; var depth = 0 }
        let box = Box(); box.depth = depth
        CGPDFDictionaryApplyBlock(xo, { _, obj, info in
            let box = Unmanaged<Box>.fromOpaque(info!).takeUnretainedValue()
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(obj, .stream, &stream), let stream, let d = CGPDFStreamGetDictionary(stream) else { return true }
            var name: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(d, "Subtype", &name), let name else { return true }
            let sub = String(cString: name)
            if sub == "Image" {
                var w = 0, h = 0
                CGPDFDictionaryGetInteger(d, "Width", &w); CGPDFDictionaryGetInteger(d, "Height", &h)
                box.sizes.append(Size(w: w, h: h))
            } else if sub == "Form" {
                var inner: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(d, "Resources", &inner), let inner { PDFInspect.collect(inner, depth: box.depth + 1, into: &box.sizes) }
            }
            return true
        }, Unmanaged.passUnretained(box).toOpaque())
        out += box.sizes
    }
}

extension WKHTTPCookieStore {
    func allCookies() async -> [HTTPCookie] { await withCheckedContinuation { c in getAllCookies { c.resume(returning: $0) } } }
}
