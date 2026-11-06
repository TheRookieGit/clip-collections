import AppKit
import NewsCapture
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var model: AppModel!
    let ui = MainState()
    var window: NSWindow!
    var settings: NSWindow?
    private var statusMenu: StatusMenu?
    private var keyMonitor: Any?
    private var arrowMonitor: Any?
    private var hubTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launch = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = launch?.eventID == kAEOpenApplication
            && launch?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        do { model = try AppModel() } catch {
            let a = NSAlert(); a.messageText = "拾闻打不开数据：\(error.localizedDescription)"; a.runModal()
            NSApp.terminate(nil)
            return
        }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "拾闻"
        // The paper runs up under the traffic lights; the masthead carries the name.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: MainView(model: model, ui: ui, detail: DetailState()))
        window.delegate = self
        // Closing only hides the window; the queue and sync keep running from the menu bar.
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("NewsWindow")
        if !window.setFrameUsingName("NewsWindow") { window.center() }
        NSApp.mainMenu = buildMenu()
        statusMenu = StatusMenu(model: model) { [weak self] in self?.showWindow() }
        if atLogin { NSApp.setActivationPolicy(.accessory) } else { showWindow() }

        // Up and down walk the list, as they would in a table.
        arrowMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, NSApp.keyWindow === self.window, !(self.window.firstResponder is NSTextView),
                  e.keyCode == 125 || e.keyCode == 126 else { return e }
            self.ui.move(by: e.keyCode == 125 ? 1 : -1, in: self.model)
            return nil
        }

        // ⌘V outside a text field pastes into the app; a picture pastes into the app even from a text field.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, e.charactersIgnoringModifiers == "v",
                  NSApp.keyWindow === self.window else { return e }
            let inText = self.window.firstResponder is NSTextView
            let hasImage = NSPasteboard.general.canReadItem(withDataConformingToTypes: ["public.image"])
                || !(NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ?? []).isEmpty
            if inText && !hasImage { return e }
            self.model.notice = nil
            self.model.pasteClipboard()
            return nil
        }

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.startCloudLink()
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(20))
                    await self?.model.syncAll()
                    self?.model.runQueue()
                }
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.stopCloudLink(); self?.model.sayGoodbye("sleeping") }
        })
        model.startCloudLink()
        model.runQueue()
        Task { await model.syncAll() }
        // New items in the hub reach no long poll here, so it is asked every few minutes, and on coming to the front.
        hubTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.model.syncHub() } }
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.model.syncHub() } }
        })
        #if DEBUG
        model.snapshot = { [weak self] spec in self?.takeSnapshot(spec) }
        model.runTestCommands()
        #endif
    }

    #if DEBUG
    /// "<file> <light|dark> <row to select, or none>": draws the window to a file, no screen permission needed.
    func takeSnapshot(_ spec: String) {
        let p = spec.split(separator: " ").map(String.init)
        guard p.count >= 2 else { return }
        window.appearance = NSAppearance(named: p[1] == "dark" ? .darkAqua : .aqua)
        if p.count > 2, p[2] == "settings" {
            openSettings()
            settings?.appearance = window.appearance
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                guard let v = settings?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: p[0]))
            }
            return
        }
        ui.selection = p.count > 2 ? ui.shown(in: model).dropFirst(Int(p[2]) ?? 0).first?.id : nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard let v = window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: p[0]))
        }
    }
    #endif

    func showWindow() {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ n: Notification) {
        if (n.object as? NSWindow) === window { NSApp.setActivationPolicy(.accessory) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ n: Notification) {
        model?.stopCloudLink()
        model?.sayGoodbye("quit", wait: true)
    }

    @objc func openSettings() {
        if settings == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 660), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "设置"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.contentView = NSHostingView(rootView: SettingsView(model: model, ui: SettingsState()))
            w.isReleasedWhenClosed = false
            w.center()
            settings = w
        }
        settings?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// ⌘Q asks first, since quitting stops the queue and the shortcut is easy to hit; every other way out does not.
    @objc func quitFromMenu(_ sender: Any?) {
        if NSApp.currentEvent?.type == .keyDown {
            let a = NSAlert()
            a.messageText = "要退出拾闻吗？"
            a.informativeText = "退出后，网页版保存的新闻要等下次打开才会处理。只想收起窗口的话，可以关闭窗口（⌘W），拾闻会继续在菜单栏运行。"
            a.addButton(withTitle: "退出")
            a.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
            NSApp.activate()
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        NSApp.terminate(sender)
    }

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        let app = NSMenu()
        app.addItem(withTitle: "关于拾闻", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let prefs = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        app.addItem(prefs)
        app.addItem(.separator())
        app.addItem(withTitle: "隐藏拾闻", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let quit = NSMenuItem(title: "退出拾闻", action: #selector(quitFromMenu(_:)), keyEquivalent: "q")
        quit.target = self
        app.addItem(quit)
        main.addItem(withTitle: "拾闻", action: nil, keyEquivalent: "").submenu = app
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "编辑", action: nil, keyEquivalent: "").submenu = edit
        let win = NSMenu(title: "窗口")
        win.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(withTitle: "窗口", action: nil, keyEquivalent: "").submenu = win
        return main
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
