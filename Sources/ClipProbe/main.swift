import AppKit
import ClipCapture
import WebKit

// Stage 1 prototype.
//   ClipProbe <link>…                 capture each link into probe-output/ and print what reached the PDF
//   ClipProbe --login <site>          open a visible window to log in; close it when done
// Readability is read from Resources/vendor (the app bundles the same file).

let args = Array(CommandLine.arguments.dropFirst())
NSApplication.shared.setActivationPolicy(args.first == "--login" ? .regular : .accessory)

@MainActor func report(_ r: CaptureResult) {
    func opt(_ s: String) -> String { s.isEmpty ? "-" : s }
    print("""
    ── \(r.requested)
       状态: \(r.status.rawValue)  类型: \(r.kind)  方式: \(r.mode)
       原因: \(opt(r.reason))
       最终地址: \(opt(r.finalURL))
       标题: \(opt(r.title))
       来源: \(opt(r.source))  发布: \(opt(r.publishedAt))  正文字数: \(r.textLength)  视频: \(r.isVideo)
       图片: 应有 \(r.expectedImages.map(String.init) ?? "?") / 下载 \(r.downloadedImages) / 渲染 \(r.renderedImages) / PDF 实含 \(r.pdfImages)
       PDF: \(r.pdf?.path ?? "-")  页数 \(r.pdfPages)
    """)
    for f in r.failures.prefix(10) { print("       ! \(f)") }
}

/// No network: a fixture note with a very tall picture, to check nothing is cut across pages and the counts add up.
@MainActor func selfTest() async -> Bool {
    var ok = true
    func expect(_ c: Bool, _ what: String) { print(c ? "  ok  \(what)" : "  FAIL \(what)"); if !c { ok = false } }

    let bad = ["file:///etc/hosts", "ftp://a.com/x", "http://localhost/", "http://127.1/", "http://0x7f.0.0.1/", "http://2130706433/",
               "http://10.0.0.1/", "http://192.168.1.1/", "http://172.16.0.1/", "http://169.254.169.254/", "http://[::1]/",
               "http://[fe80::1]/", "http://[::ffff:192.168.0.1]/", "http://printer.local/", "http://intranet/"]
    for u in bad { expect((try? URLGuard.check(URL(string: u)!)) == nil, "拒绝 \(u)") }
    for u in ["https://www.xiaohongshu.com/explore/abc", "http://xhslink.com/a/b", "https://mp.weixin.qq.com/s/x", "http://8.8.8.8/"] {
        expect((try? URLGuard.check(URL(string: u)!)) != nil, "接受 \(u)")
    }

    expect(XHS.best(["http://sns-webpic-qc.xhscdn.com/1/abc!nd_prv_wlteh_webp_3", "http://sns-webpic-qc.xhscdn.com/1/abc!nd_dft_wlteh_webp_3"])?.contains("_dft_") == true, "dft 优先于 prv，且改成 https")
    expect(XHS.best(["https://a.xhscdn.com/x!nd_dft_1", "https://a.xhscdn.com/x!h5_1080jpg"])?.contains("h5_1080") == true, "1080 优先于 dft")
    let urls = (0..<12).map { #"["http://sns-webpic-qc.xhscdn.com/1/img\#($0)!nd_dft_wlteh_webp_3"]"# }.joined(separator: ",")
    let json = #"{"id":"6a","title":"t","desc":"d","author":"a","time":1700000000000,"type":"normal","hasVideo":false,"images":[\#(urls),[]],"found":1}"#
    let note = XHS.parse(json: json)
    expect(note?.expected == 13, "笔记图片总数不受 9 张限制，没有地址的图也计入总数")
    let short = #"{"id":"6b","images":[["https://a.xhscdn.com/x!nd_dft_1"]],"pageCount":6}"#
    expect(XHS.parse(json: short)?.expected == 6, "imageList 比页面计数少时，以页面计数为准")
    expect(XHS.noteID(URL(string: "https://www.xiaohongshu.com/explore/6543210fedcba9876543210f?xsec_token=x")!) == "6543210fedcba9876543210f", "解析笔记 id")

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clip-selftest-\(UUID())")
    defer { try? FileManager.default.removeItem(at: dir) }
    let r = await Capturer().renderFixture(dir: dir)
    print("  图片：渲染 \(r.renderedImages)，PDF 实含 \(r.pdfImages)，页数 \(r.pdfPages)")
    expect(r.renderedImages == 5 && r.pdfImages == 5, "5 张图都进了 PDF，没有被分页切成两半")
    expect(r.pdfPages >= 4, "内容分到多页")
    if let p = r.pdf { try? FileManager.default.copyItem(at: p, to: URL(fileURLWithPath: "probe-output/selftest.pdf")) }
    return ok
}

final class Login: NSObject, NSWindowDelegate {
    func windowWillClose(_ n: Notification) { exit(0) }
}

@MainActor func login(_ site: String) {
    guard let url = URL(string: site) else { fatalError("bad url") }
    let view = Capturer.makeWebView(userAgent: Capturer.desktopUA)
    let win = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    win.title = "登录后关闭窗口：\(site)"
    win.contentView = view
    let d = Login(); win.delegate = d; objc_setAssociatedObject(win, "d", d, .OBJC_ASSOCIATION_RETAIN)
    win.center(); win.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    view.load(URLRequest(url: url))
}

Task { @MainActor in
    if args.first == "--login", args.count == 2 { login(args[1]); return }
    if args.first == "--inspect", args.count == 2 { print(await Capturer().inspectPage(args[1])); exit(0) }
    if args.first == "--selftest" { exit(await selfTest() ? 0 : 1) }
    guard !args.isEmpty else { print("用法：ClipProbe <链接>… | ClipProbe --login <网址>"); exit(2) }
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let js = try! String(contentsOf: root.appendingPathComponent("Resources/vendor/Readability-0.6.0.js"), encoding: .utf8)
    let out = root.appendingPathComponent("probe-output")
    let cap = Capturer(readabilityJS: js)
    var failed = 0
    for (i, link) in args.enumerated() {
        let r = await cap.capture(link, workDir: out.appendingPathComponent("work-\(i)"), outFile: out.appendingPathComponent("\(i)-result.pdf"))
        report(r)
        if r.status != .saved { failed += 1 }
    }
    exit(failed == 0 ? 0 : 1)
}
NSApplication.shared.run()
