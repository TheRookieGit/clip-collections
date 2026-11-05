import AppKit
import ClipCapture
import WebKit

/// A visible browser sharing the capture engine's data store, so a login here applies to later captures.
@MainActor
enum LoginWindow {
    private static var open: [NSWindow] = []

    static func open(_ site: String) {
        guard let url = URL(string: site.trimmingCharacters(in: .whitespacesAndNewlines)), (try? URLGuard.check(url)) != nil else { return }
        let view = Capturer.makeWebView(userAgent: Capturer.desktopUA)
        let w = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "登录后关闭这个窗口"
        w.contentView = view
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        view.load(URLRequest(url: url))
        open.append(w)
    }
}
