import AppKit

// The same file sits in My Collections, AutoReceipt, FoodCollection and News Collections: change all four together.
//
// My Collections is the one menu bar icon. While it runs, the other apps hide their own icon and hand it their menu,
// so what they show stays theirs. When it quits or crashes their icons come back by themselves.

enum MenuHub {
    static let bundleID = "com.therookiegit.MyCollections"
    static let ask = Notification.Name("com.therookiegit.menuhub.ask")
    static let tell = Notification.Name("com.therookiegit.menuhub.tell")
    static let perform = Notification.Name("com.therookiegit.menuhub.perform")

    struct Row: Codable {
        var title = ""
        var enabled = false
        var checked = false
        var separator = false
    }
    struct Menu: Codable {
        var rows: [Row]
        var symbol: String?  // set while the app's own icon would differ from normal, e.g. syncing
        var label: String?
    }
}

/// The app's side: hides its icon while the hub runs and answers with what its menu would show right now.
@MainActor
final class MenuHubClient: NSObject {
    private let item: NSStatusItem
    private let source: NSMenuDelegate
    private let id = Bundle.main.bundleIdentifier ?? ""
    private let shown = NSMenu() // kept, so a click lands on the entry the hub showed
    private var watch: NSKeyValueObservation?

    /// What the icon shows when it isn't the normal one; the hub's icon shows it instead.
    var status: (symbol: String, label: String)? { didSet { tell() } }

    init(item: NSStatusItem, source: NSMenuDelegate) {
        self.item = item
        self.source = source
        super.init()
        let center = DistributedNotificationCenter.default()
        // deliverImmediately: otherwise nothing arrives while the app is in the background, which is nearly always.
        center.addObserver(self, selector: #selector(asked), name: MenuHub.ask, object: nil, suspensionBehavior: .deliverImmediately)
        center.addObserver(self, selector: #selector(performEntry(_:)), name: MenuHub.perform, object: id, suspensionBehavior: .deliverImmediately)
        watch = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            Task { @MainActor in self?.followHub() }
        }
        followHub()
        tell()
    }

    private func followHub() {
        item.isVisible = NSRunningApplication.runningApplications(withBundleIdentifier: MenuHub.bundleID).isEmpty
    }

    @objc private func asked() {
        followHub()
        tell()
    }

    private func tell() {
        guard !item.isVisible else { return }
        source.menuNeedsUpdate?(shown)
        let rows = shown.items.map {
            $0.isSeparatorItem ? MenuHub.Row(separator: true)
                : MenuHub.Row(title: $0.title, enabled: $0.isEnabled && $0.action != nil, checked: $0.state == .on)
        }
        let menu = MenuHub.Menu(rows: rows, symbol: status?.symbol, label: status?.label)
        guard let data = try? JSONEncoder().encode(menu), let json = String(data: data, encoding: .utf8) else { return }
        DistributedNotificationCenter.default().postNotificationName(MenuHub.tell, object: id, userInfo: ["menu": json], options: [.deliverImmediately])
    }

    @objc private func performEntry(_ note: Notification) {
        guard let index = note.userInfo?["index"] as? Int, shown.items.indices.contains(index) else { return }
        let entry = shown.items[index]
        guard entry.isEnabled, let action = entry.action else { return }
        NSApp.sendAction(action, to: entry.target, from: entry)
    }
}
