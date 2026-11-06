import Foundation

/// A Xiaohongshu note as read from the page's own data. `expected` is the note's image count: the number the PDF is
/// checked against, not however many images happened to load.
public struct XHSNote: Equatable {
    public var id: String
    public var title: String
    public var body: String
    public var author: String
    public var publishedAt: Date?
    public var isVideo: Bool
    /// The sharpest usable address of each image, in note order. Repeats stay: the count is the note's own.
    public var imageURLs: [String]
    /// The total shown by the page itself, 0 when it shows none.
    public var pageCount = 0
    /// Never below the page's own counter, so a shortened imageList shows up as missing images.
    public var expected: Int { max(imageURLs.count, pageCount) }
}

public enum XHS {
    public static func isXHS(_ url: URL) -> Bool {
        guard let h = url.host?.lowercased() else { return false }
        return h == "xiaohongshu.com" || h.hasSuffix(".xiaohongshu.com") || h == "xhslink.com" || h.hasSuffix(".xhslink.com")
            || h == "xhslink.cn" || h.hasSuffix(".xhslink.cn")
            || h == "rednote.com" || h.hasSuffix(".rednote.com")
    }

    /// The note id in /explore/<id>, /discovery/item/<id>, /note/<id> and similar.
    public static func noteID(_ url: URL) -> String? {
        url.pathComponents.last { $0.range(of: #"^[0-9a-f]{24}$"#, options: .regularExpression) != nil }
    }

    /// Where note images may come from. Share links now also land on rednote.com, with images on rednotecdn.com.
    static let imageHosts = ["xhscdn.com/", "xiaohongshu.com/", "rednotecdn.com/", "rednote.com/"]

    /// The same order as parseShare in my-collections: 1080 first, then dft, then anything else; prv (heavily
    /// compressed previews) last.
    public static func rank(_ u: String) -> Int {
        if u.contains("!h5_1080") { return 3 }
        if u.contains("_dft_") { return 2 }
        if u.contains("_prv_") { return 0 }
        return 1
    }

    public static func best(_ urls: [String]) -> String? {
        var out: String?
        for raw in urls {
            let u = raw.hasPrefix("//") ? "https:" + raw : raw.replacingOccurrences(of: #"^http:"#, with: "https:", options: .regularExpression)
            guard u.hasPrefix("https://"), imageHosts.contains(where: u.contains) else { continue }
            if out == nil || rank(u) > rank(out!) { out = u }
        }
        return out
    }

    /// Why images went missing, short enough to show under an item. `failures` are in note order.
    public static func failureSummary(_ failures: [String]) -> String {
        guard let first = failures.first else { return "" }
        return failures.count > 1 ? "\(first)，共 \(failures.count) 张失败" : first
    }

    /// Runs in the page's own JavaScript world, the only place __INITIAL_STATE__ exists. Walks the state instead of
    /// following one fixed path, because the desktop and mobile pages nest the note differently. Returns JSON or null.
    public static let extractJS = #"""
    const wanted = location.pathname.split('/').filter(s => /^[0-9a-f]{24}$/.test(s)).pop() || '';
    const state = window.__INITIAL_STATE__;
    if (!state) return null;
    const seen = new WeakSet(); const found = [];
    const walk = (o, depth) => {
      if (!o || typeof o !== 'object' || depth > 12 || seen.has(o) || found.length > 20) return;
      seen.add(o);
      try {
        if (Array.isArray(o.imageList) && o.imageList.length && ('desc' in o || 'title' in o || 'noteId' in o)) found.push(o);
        for (const k of Object.keys(o)) { let v; try { v = o[k]; } catch { continue; } walk(v, depth + 1); }
      } catch {}
    };
    walk(state, 0);
    const note = found.find(n => (n.noteId || n.id) === wanted) || (found.length === 1 ? found[0] : null);
    if (!note) return JSON.stringify({ found: found.length, images: null });
    const urlsOf = (i) => {
      const out = [];
      for (const k of ['urlDefault', 'url', 'urlPre', 'original']) if (typeof i[k] === 'string') out.push(i[k]);
      for (const x of (i.infoList || [])) if (x && typeof x.url === 'string') out.push(x.url);
      return out;
    };
    // The page's own "1/9" counter: a second source for the total, independent of imageList.
    const fraction = [...document.querySelectorAll('.fraction, .swiper-pagination-fraction, [class*="fraction"]')]
      .map(e => (e.textContent || '').match(/\d+\s*\/\s*(\d+)/)).find(Boolean);
    const pageCount = fraction ? parseInt(fraction[1], 10) : 0;
    return JSON.stringify({
      id: note.noteId || note.id || wanted, title: note.title || '', desc: note.desc || '',
      author: (note.user && (note.user.nickname || note.user.nickName)) || '',
      time: note.time || 0, type: note.type || '', hasVideo: !!note.video,
      images: note.imageList.map(urlsOf), found: found.length, pageCount,
    });
    """#

    public static func parse(json: String) -> XHSNote? {
        guard let data = json.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = o["images"] as? [[String]] else { return nil }
        // An entry with no usable address still counts: the check must then report a missing image, not hide it.
        let urls = images.map { XHS.best($0) ?? "" }
        let ms = (o["time"] as? NSNumber)?.doubleValue ?? 0
        return XHSNote(id: o["id"] as? String ?? "", title: o["title"] as? String ?? "", body: o["desc"] as? String ?? "",
                       author: o["author"] as? String ?? "", publishedAt: ms > 0 ? Date(timeIntervalSince1970: ms / 1000) : nil,
                       isVideo: (o["type"] as? String) == "video" || (o["hasVideo"] as? Bool ?? false), imageURLs: urls,
                       pageCount: (o["pageCount"] as? Int) ?? 0)
    }
}
