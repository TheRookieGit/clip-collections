import AppKit
import ClipCapture
import ServiceManagement

/// The menu bar icon that keeps the app reachable with no window open. Rebuilt each time it opens.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let showWindow: () -> Void
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    init(model: AppModel, showWindow: @escaping () -> Void) {
        self.model = model
        self.showWindow = showWindow
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.button?.image = Self.glyph
        item.button?.toolTip = "拾闻"
        if !UserDefaults.standard.bool(forKey: "loginItemDefaulted") {
            UserDefaults.standard.set(true, forKey: "loginItemDefaulted")
            try? SMAppService.mainApp.register()
        }
    }

    /// A small seal with 闻 in it, drawn as a template so it follows the menu bar's light and dark.
    static let glyph: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            let box = NSBezierPath(roundedRect: NSRect(x: 1.6, y: 1.6, width: 14.8, height: 14.8), xRadius: 1.6, yRadius: 1.6)
            box.lineWidth = 1.3
            box.stroke()
            let t = NSAttributedString(string: "闻", attributes: [.font: NSFont(name: "STSongti-SC-Bold", size: 11.5) ?? .systemFont(ofSize: 11.5), .foregroundColor: NSColor.black])
            let s = t.size()
            t.draw(at: NSPoint(x: 9 - s.width / 2, y: 9 - s.height / 2 + 0.4))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "拾闻"
        return image
    }()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func info(_ title: String) {
            let e = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            e.isEnabled = false
            menu.addItem(e)
        }
        menu.addItem(action("打开拾闻", #selector(openWindow)))
        menu.addItem(action("保存剪贴板内容", #selector(saveClipboard)))
        menu.addItem(.separator())
        let active = model.visible.filter { $0.status == .pending || $0.status == .processing }.count
        let attention = model.visible.filter { $0.status == .failed || $0.status == .incomplete }.count
        info(active > 0 ? "处理中 \(active) 条" : "没有待处理的新闻")
        if attention > 0 { info("需要处理 \(attention) 条") }
        for c in model.visible.prefix(5) { info("\(c.status.label)　\(c.displayTitle.prefix(26))") }
        menu.addItem(.separator())
        if !model.cloud.configured { info("云端：未设置") }
        else if let e = model.cloudError { info("云端出错：\(e.prefix(40))") }
        else { info("云端：\(model.lastCloudSync.map { "已同步 \($0.formatted(date: .omitted, time: .shortened))" } ?? "尚未同步")") }
        if !model.hubPaired { info("心愿中枢：未连接") }
        else if let e = model.hubError { info("心愿中枢出错：\(e.prefix(40))") }
        else { info("心愿中枢：\(model.lastHubSync.map { "已同步 \($0.formatted(date: .omitted, time: .shortened))" } ?? "尚未同步")") }
        let login = action("开机时自动启动", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出拾闻", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
    }

    private func action(_ title: String, _ s: Selector) -> NSMenuItem {
        let e = NSMenuItem(title: title, action: s, keyEquivalent: "")
        e.target = self
        return e
    }

    @objc private func openWindow() { showWindow() }

    @objc private func saveClipboard() {
        model.notice = nil
        model.pasteClipboard(direct: true)
        if let n = model.notice {
            model.notice = nil
            let a = NSAlert(); a.messageText = n; a.runModal()
        }
    }

    @objc private func toggleLogin() {
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
        else {
            try? SMAppService.mainApp.register()
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        }
    }
}
