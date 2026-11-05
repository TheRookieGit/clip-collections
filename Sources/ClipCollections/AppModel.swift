import AppKit
import ClipCapture
import Observation
import UniformTypeIdentifiers

/// Everything the app does: the list, the queue that turns items into PDFs, the desktop copies and the cloud sync.
@MainActor @Observable
final class AppModel {
    static let defaultCloud = "https://gxhqguewzkvogtilfrbo.supabase.co/functions/v1/api"
    /// Gaps between Xiaohongshu pages, so saving several at once reads like one person browsing.
    static let xhsGap: TimeInterval = 30

    @ObservationIgnored let paths: Paths
    @ObservationIgnored let store: ClipStore
    @ObservationIgnored private let capturer: Capturer
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var link: Task<Void, Never>?
    @ObservationIgnored private var pushTimer: Task<Void, Never>?
    @ObservationIgnored private var lastXHS = Date.distantPast
    @ObservationIgnored private var syncing = false

    var clips: [Clip] = []
    var secrets: Secrets
    var cloudURL: String { didSet { UserDefaults.standard.set(cloudURL, forKey: "cloudURL") } }
    /// Screenshots waiting to become one item.
    var draft: [URL] = []
    var notice: String?
    var cloudError: String?
    var lastCloudSync: Date?
    var hubError: String?
    var lastHubSync: Date?
    var hubSecret = ""
    var hubConnecting = false
    @ObservationIgnored private var hubSyncing = false
    @ObservationIgnored var hubTransport: Hub.Transport = Hub.live
    var hubPaired: Bool { !secrets.hubToken.isEmpty }

    var cloud: CloudAPI { CloudAPI(url: cloudURL.trimmingCharacters(in: .whitespacesAndNewlines), passcode: secrets.cloudPasscode.trimmingCharacters(in: .whitespacesAndNewlines)) }
    var visible: [Clip] { clips.filter { !$0.deleted }.sorted { $0.createdAt > $1.createdAt } }
    var topics: [String] { Array(Set(visible.map(\.topic).filter { !$0.isEmpty })).sorted() }
    var hasKey: Bool { !secrets.anthropicKey.trimmingCharacters(in: .whitespaces).isEmpty }

    init(paths: Paths = AppModel.defaultPaths) throws {
        self.paths = paths
        try paths.ensure()
        store = try ClipStore(file: paths.database)
        secrets = Secrets.load(paths.secrets)
        cloudURL = UserDefaults.standard.string(forKey: "cloudURL") ?? Self.defaultCloud
        capturer = Capturer(readabilityJS: Capturer.bundledReadability() ?? "")
        #if DEBUG
        if let u = ProcessInfo.processInfo.environment["CLIP_TEST_CLOUD"] { cloudURL = u; secrets.cloudPasscode = "test-only" }
        if let t = ProcessInfo.processInfo.environment["CLIP_TEST_HUB_TOKEN"] { secrets.hubToken = t }
        #endif
        clips = store.all()
        // Interrupted when the app last stopped.
        for c in clips where c.status == .processing { change(c.id) { $0.status = .pending } }
    }

    /// Debug builds can run against a throwaway folder, so a test never touches real data or the real desktop.
    nonisolated static var defaultPaths: Paths {
        #if DEBUG
        if let root = ProcessInfo.processInfo.environment["CLIP_TEST_ROOT"] {
            let r = URL(fileURLWithPath: root)
            return Paths(root: r.appendingPathComponent("data"), desktop: r.appendingPathComponent("桌面"))
        }
        #endif
        return Paths()
    }

    func saveSecrets() {
        do { try secrets.save(paths.secrets) } catch { notice = "设置没保存：\(error.localizedDescription)" }
        startCloudLink()
        Task { await sync() }
    }

    // MARK: Changing items

    private func change(_ id: String, _ edit: (inout Clip) -> Void) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        edit(&clips[i])
        clips[i].updatedAt = Date()
        clips[i].dirty = true
        store.put(clips[i])
        schedulePush()
    }

    private func insert(_ c: Clip) {
        clips.append(c)
        store.put(c)
        schedulePush()
        runQueue()
    }

    func clip(_ id: String) -> Clip? { clips.first { $0.id == id } }

    func addLink(_ text: String) {
        guard let link = LinkText.firstURL(text) ?? URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)).map(\.absoluteString), !link.isEmpty else {
            notice = "没有找到链接"
            return
        }
        guard let url = URL(string: link), (try? URLGuard.check(url)) != nil else {
            notice = "只支持公开的 http/https 链接"
            return
        }
        if let same = visible.first(where: { $0.url == link }) {
            notice = "这条已经保存过了：\(same.displayTitle)"
            return
        }
        insert(Clip(kind: .link, url: link))
    }

    /// Keeps the files as they are: the original pictures.
    func addShots(_ files: [URL]) {
        guard !files.isEmpty else { return }
        var c = Clip(kind: .shots)
        let dir = paths.shotDir(c.id)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (i, f) in files.enumerated() {
                let name = String(format: "%03d.%@", i, f.pathExtension.isEmpty ? "png" : f.pathExtension.lowercased())
                try FileManager.default.copyItem(at: f, to: dir.appendingPathComponent(name))
                c.shotFiles.append(name)
            }
            insert(c)
        } catch { notice = "截图没保存：\(error.localizedDescription)" }
    }

    func update(_ id: String, title: String, topic: String, note: String) {
        change(id) { c in
            if c.title != title { c.title = title; c.titleEdited = true }
            if c.topic != topic { c.topic = topic; c.topicEdited = true }
            c.note = note
        }
    }

    func retry(_ id: String) {
        change(id) { $0.status = .pending; $0.reason = "" }
        runQueue()
    }

    /// Removes the item and the app's own files. The desktop copy is the user's, and stays.
    func delete(_ id: String) {
        change(id) { $0.deleted = true; $0.status = .saved }
        purge(id)
    }

    private func purge(_ id: String) {
        try? FileManager.default.removeItem(at: paths.pdf(id))
        try? FileManager.default.removeItem(at: paths.shotDir(id))
    }

    #if DEBUG
    @ObservationIgnored var snapshot: ((String) -> Void)?

    private func seedForDesign() {
        let day: TimeInterval = 86400
        func add(_ title: String, _ source: String, _ topic: String, _ date: String, _ status: ClipStatus, _ age: TimeInterval, reason: String = "", url: String = "https://example.com/a", shots: Int = 0, full: Bool = false, video: Bool = false, want: Int? = nil, have: Int? = nil) {
            var c = Clip(kind: shots > 0 ? .shots : .link, url: url, now: Date().addingTimeInterval(-age))
            c.title = title; c.source = source; c.topic = topic; c.publishedAt = date; c.status = status; c.reason = reason; c.fullPage = full; c.videoMissing = video
            c.expectedImages = want; c.embeddedImages = have; c.hasPDF = status == .saved || status == .incomplete
            c.dirty = false; c.shotFiles = (0..<shots).map { "\($0).png" }
            if status == .saved { c.exportedAt = Date(); c.desktopFile = "/Users/x/Desktop/2026-11-04 \(title).pdf" }
            clips.append(c)
        }
        add("美联储利率决议后，长端美债收益率为何继续上行", "财经观察", "投资", "2026-11-03", .saved, 3600, want: 6, have: 6)
        add("中央政治局会议释放的五个信号", "新华社", "政策", "2026-11-04", .processing, 600, url: "https://example.com/b")
        add("", "", "", "", .pending, 300, url: "https://www.xiaohongshu.com/explore/6ac6f7b900000")
        add("丰田章男的孤独：新发动机一箱油跑 1200 公里", "小红书 · 资本车讯", "汽车", "2026-10-07", .incomplete, day + 2000, reason: "图片不全：笔记有 12 张，PDF 里只有 9 张", want: 12, have: 9)
        add("半导体设备出口新规解读", "财新", "科技", "2026-11-02", .saved, day + 5000, shots: 3)
        add("", "", "", "", .failed, 2 * day + 800, reason: "小红书暂时限制了这次访问：可以过一会儿重试，也可以登录网站后重试，或者改用截图", url: "https://xhslink.com/a/abc")
        add("土豆泡芙｜外脆里软，材料简单", "小红书 · 吴所不甜", "生活", "2026-10-07", .saved, 2 * day + 5000, video: true)
        add("BBC News - 今日要闻", "BBC", "国际", "", .saved, 9 * day, full: true)
    }

    /// A test states what is in the list and sends text or files, as a paste would.
    func runTestCommands() {
        guard let file = ProcessInfo.processInfo.environment["CLIP_TEST_ROOT"].map({ URL(fileURLWithPath: $0).appendingPathComponent("commands") }) else { return }
        Task { [weak self] in
            var done = 0
            while let self {
                try? await Task.sleep(for: .milliseconds(400))
                let lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
                while done < lines.count {
                    let parts = lines[done].split(separator: " ", maxSplits: 1).map(String.init)
                    done += 1
                    switch parts[0] {
                    case "link": self.addLink(parts[1])
                    case "shots": self.addShots(parts[1].split(separator: "|").map { URL(fileURLWithPath: String($0)) })
                    case "delete": if let c = self.visible.first(where: { $0.url == parts[1] || $0.title == parts[1] }) { self.delete(c.id) }
                    case "seed": self.seedForDesign()
                    case "snapshot": self.snapshot?(parts[1])
                    default: break
                    }
                }
                let state = self.clips.map { ["id": $0.id, "status": $0.status.rawValue, "title": $0.displayTitle, "reason": $0.reason, "deleted": "\($0.deleted)", "desktop": $0.desktopFile ?? "", "dirty": "\($0.dirty)"] }
                if let d = try? JSONSerialization.data(withJSONObject: state) { try? d.write(to: file.deletingLastPathComponent().appendingPathComponent("state.json")) }
            }
        }
    }
    #endif

    func openPDF(_ c: Clip) { NSWorkspace.shared.open(paths.pdf(c.id)) }

    func reveal(_ c: Clip) {
        let desktop = c.desktopFile.map { URL(fileURLWithPath: $0) }
        if let desktop, FileManager.default.fileExists(atPath: desktop.path) {
            NSWorkspace.shared.activateFileViewerSelecting([desktop])
        } else {
            if desktop != nil { notice = "桌面上的 PDF 已被移走，这里显示的是应用保存的副本" }
            NSWorkspace.shared.activateFileViewerSelecting([paths.pdf(c.id)])
        }
    }

    func openOriginal(_ c: Clip) {
        if let u = URL(string: c.url), (try? URLGuard.check(u)) != nil { NSWorkspace.shared.open(u) }
    }

    /// Asked for by hand: a new copy, even if the earlier one was moved away.
    func exportAgain(_ id: String) {
        guard let c = clip(id), c.hasPDF else { return }
        do {
            let file = try Exporter.export(pdf: paths.pdf(id), title: c.displayTitle, date: Date(), to: paths.desktop)
            change(id) { $0.exportedAt = Date(); $0.desktopFile = file.path }
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } catch { notice = "没能放到桌面：\(error.localizedDescription)" }
    }

    // MARK: Clipboard

    /// Links become items at once. Pictures go to the tray in the window, or straight to one item when `direct`.
    func pasteClipboard(direct: Bool = false) {
        let pb = NSPasteboard.general
        let files = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []).filter(Self.isImage)
        var images = files
        if images.isEmpty, let saved = Self.imageOnPasteboard(pb, dir: paths.work) { images = [saved] }
        if !images.isEmpty {
            if direct { addShots(images) } else { draft += images }
            return
        }
        if let s = pb.string(forType: .string), LinkText.firstURL(s) != nil { addLink(s); return }
        notice = "剪贴板里没有链接或图片"
    }

    func addDropped(_ urls: [URL]) {
        let images = urls.filter(Self.isImage)
        if images.isEmpty { notice = "只能拖入图片" } else { draft += images }
    }

    func saveDraft() { addShots(draft); draft = [] }

    static func isImage(_ u: URL) -> Bool { UTType(filenameExtension: u.pathExtension)?.conforms(to: .image) ?? false }

    /// The bytes as they came, PNG when offered, so a screenshot is not recompressed.
    private static func imageOnPasteboard(_ pb: NSPasteboard, dir: URL) -> URL? {
        let name = "paste-\(UUID().uuidString)"
        if let d = pb.data(forType: .png) {
            let f = dir.appendingPathComponent(name + ".png")
            return (try? d.write(to: f)) != nil ? f : nil
        }
        if let d = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: d), let png = rep.representation(using: .png, properties: [:]) {
            let f = dir.appendingPathComponent(name + ".png")
            return (try? png.write(to: f)) != nil ? f : nil
        }
        return nil
    }

    // MARK: The queue

    func runQueue() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, let next = self.visible.filter({ $0.status == .pending }).min(by: { $0.createdAt < $1.createdAt }) {
                await self.process(next.id)
            }
            self?.worker = nil
        }
    }

    private func process(_ id: String) async {
        guard let c = clip(id) else { return }
        if c.kind == .link, let u = URL(string: c.url), XHS.isXHS(u) {
            let wait = Self.xhsGap - Date().timeIntervalSince(lastXHS)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            lastXHS = Date()
        }
        guard clip(id)?.status == .pending, clip(id)?.deleted == false else { return }
        change(id) { $0.status = .processing; $0.reason = "" }
        await sync()
        switch c.kind {
        case .link: await processLink(c)
        case .shots: await processShots(c)
        }
        try? FileManager.default.removeItem(at: paths.work.appendingPathComponent(id))
        await syncAll()
    }

    private func processLink(_ c: Clip) async {
        let r = await capturer.capture(c.url, workDir: paths.work.appendingPathComponent(c.id), outFile: paths.work.appendingPathComponent(c.id + ".pdf"))
        defer { try? FileManager.default.removeItem(at: paths.work.appendingPathComponent(c.id + ".pdf")) }
        guard r.status != .failed, let made = r.pdf else {
            change(c.id) { $0.status = .failed; $0.reason = r.reason.isEmpty ? "保存失败" : r.reason }
            return
        }
        do {
            try? FileManager.default.removeItem(at: paths.pdf(c.id))
            try FileManager.default.moveItem(at: made, to: paths.pdf(c.id))
        } catch {
            change(c.id) { $0.status = .failed; $0.reason = "PDF 没保存：\(error.localizedDescription)" }
            return
        }
        var topic = ""
        if hasKey, !(clip(c.id)?.topicEdited ?? false), !r.excerpt.isEmpty {
            topic = (try? await ClaudeAPI.recognize(text: r.excerpt, topics: topics, transport: ClaudeAPI.live(apiKey: secrets.anthropicKey)))?.topic ?? ""
        }
        change(c.id) { x in
            x.hasPDF = true
            if !x.titleEdited, !r.title.isEmpty { x.title = r.title }
            if !r.source.isEmpty { x.source = r.source }
            if !r.publishedAt.isEmpty { x.publishedAt = String(r.publishedAt.prefix(10)) }
            if !x.topicEdited, !topic.isEmpty { x.topic = topic }
            x.fullPage = r.mode == "fullpage"
            x.videoMissing = r.isVideo
            x.expectedImages = r.expectedImages
            x.embeddedImages = r.pdfImages + r.repeatedImages
            x.status = r.status == .incomplete ? .incomplete : .saved
            x.reason = r.reason
        }
        exportIfDue(c.id)
    }

    private func processShots(_ c: Clip) async {
        do {
            try await fetchShots(c.id)
            guard let c = clip(c.id) else { return }
            let dir = paths.shotDir(c.id)
            let files = c.shotFiles.map { dir.appendingPathComponent($0) }
            var found: Recognized?
            var note = ""
            if hasKey {
                do {
                    let parts = files.prefix(8).flatMap { ClaudeAPI.parts(of: $0) }.prefix(12)
                    found = try await ClaudeAPI.recognize(images: Array(parts), topics: topics, transport: ClaudeAPI.live(apiKey: secrets.anthropicKey))
                } catch { note = "没有识别出标题和主题：\(error.localizedDescription)" }
            } else { note = "还没填 API Key，没有识别标题和主题" }
            change(c.id) { x in
                if let found {
                    if !x.titleEdited, !found.title.isEmpty { x.title = found.title }
                    if !found.source.isEmpty { x.source = found.source }
                    if !found.publishedAt.isEmpty { x.publishedAt = found.publishedAt }
                    if !x.topicEdited, !found.topic.isEmpty { x.topic = found.topic }
                }
            }
            guard let now = clip(c.id) else { return }
            let meta = ShotPDF.Meta(title: now.displayTitle, source: now.source, publishedAt: now.publishedAt, link: "", savedAt: Date())
            try ShotPDF.build(images: files, meta: meta, to: paths.pdf(c.id))
            change(c.id) { $0.hasPDF = true; $0.status = .saved; $0.reason = note }
            exportIfDue(c.id)
        } catch {
            change(c.id) { $0.status = .failed; $0.reason = error.localizedDescription }
        }
    }

    /// Screenshots sent from the web page, fetched through signed links on this project's own host.
    private func fetchShots(_ id: String) async throws {
        guard let c = clip(id), c.shotFiles.isEmpty else { return }
        if c.cloudShots.isEmpty {
            try await fetchHubShots(c)
            return
        }
        let urls = try await cloud.call(["action": "shot_urls", "paths": c.cloudShots])["urls"] as? [String: String] ?? [:]
        let dir = paths.shotDir(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let home = URL(string: cloud.url)
        var names: [String] = []
        for (i, p) in c.cloudShots.enumerated() {
            guard let s = urls[p], let u = URL(string: s), u.scheme == home?.scheme, u.host == home?.host else { throw CaptureError("截图的下载地址无效") }
            let (data, resp) = try await URLSession.shared.data(from: u)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw CaptureError("截图下载失败") }
            let name = String(format: "%03d.jpg", i)
            try data.write(to: dir.appendingPathComponent(name))
            names.append(name)
        }
        change(id) { $0.shotFiles = names }
    }

    /// Only a complete item, and only once: a file the user moved away is not made again.
    private func exportIfDue(_ id: String) {
        guard let c = clip(id), c.status == .saved, c.hasPDF, c.exportedAt == nil else { return }
        do {
            let file = try Exporter.export(pdf: paths.pdf(id), title: c.displayTitle, date: Date(), to: paths.desktop)
            change(id) { $0.exportedAt = Date(); $0.desktopFile = file.path }
        } catch {
            change(id) { $0.reason = "PDF 已保存，但没能放到桌面：\(error.localizedDescription)" }
        }
    }

    // MARK: The cloud

    private func schedulePush() {
        pushTimer?.cancel()
        pushTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { await self?.syncAll() }
        }
    }

    func syncAll() async {
        await sync()
        await syncHub()
    }

    func sync() async {
        guard cloud.configured, !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            try await pullEdits()
            try await uploadShots()
            try await pushChanges()
            lastCloudSync = Date()
            cloudError = nil
        } catch { cloudError = error.localizedDescription }
    }

    private func pullEdits() async throws {
        let edits = try await cloud.call(["action": "edits_pull"])["edits"] as? [[String: Any]] ?? []
        guard !edits.isEmpty else { return }
        var ids: [Int] = []
        for e in edits {
            guard let n = e["id"] as? Int else { continue }
            ids.append(n)
            if let p = e["patch"] as? [String: Any] { apply(p) }
        }
        try await cloud.call(["action": "edits_done", "ids": ids])
        runQueue()
    }

    /// One request from the web page. Links are checked again here, because the Mac is what opens them.
    private func apply(_ p: [String: Any]) {
        guard let id = p["id"] as? String else { return }
        switch p["op"] as? String {
        case "add":
            guard clip(id) == nil else { return }
            var c = Clip(id: id, kind: p["kind"] as? String == "shots" ? .shots : .link, url: p["url"] as? String ?? "")
            if let s = p["createdAt"] as? String, let d = Self.date(s) { c.createdAt = d }
            c.cloudShots = p["shots"] as? [String] ?? []
            if c.kind == .link, URL(string: c.url).flatMap({ try? URLGuard.check($0) }) == nil {
                c.status = .failed
                c.reason = "只支持公开的 http/https 链接"
            }
            clips.append(c)
            store.put(c)
        case "update":
            guard let c = clip(id) else { return }
            update(id, title: p["title"] as? String ?? c.title, topic: p["topic"] as? String ?? c.topic, note: p["note"] as? String ?? c.note)
        case "delete": delete(id)
        case "retry": if clip(id)?.status == .failed || clip(id)?.status == .incomplete { change(id) { $0.status = .pending; $0.reason = "" } }
        default: break
        }
    }

    private static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// Screenshots pasted on this Mac, so the web page can show them too. Originals stay here.
    private func uploadShots() async throws {
        for c in clips where !c.deleted && c.kind == .shots && c.cloudShots.isEmpty && !c.shotFiles.isEmpty {
            var done: [String] = []
            for (i, name) in c.shotFiles.enumerated() {
                guard let jpeg = CloudAPI.webJPEG(paths.shotDir(c.id).appendingPathComponent(name)) else { throw CaptureError("截图压缩失败") }
                let path = "s/\(c.id)/\(i).jpg"
                try await cloud.call(["action": "shot_upload", "path": path, "jpeg": jpeg.base64EncodedString()])
                done.append(path)
            }
            change(c.id) { $0.cloudShots = done }
        }
    }

    private func pushChanges() async throws {
        let gone = clips.filter { $0.deleted && $0.cloudGone != true }.prefix(200)
        if !gone.isEmpty {
            try await cloud.call(["action": "clips_delete", "ids": gone.map(\.id)])
            for c in gone { markGone(c.id) }
            reapTombstones()
        }
        let dirty = clips.filter { $0.dirty && !$0.deleted }.prefix(200)
        guard !dirty.isEmpty else { return }
        try await cloud.call(["action": "clips_push", "clips": dirty.map(\.cloudRow)])
        for sent in dirty {
            // Changed again while this was on its way: stays marked for the next push.
            guard let i = clips.firstIndex(where: { $0.id == sent.id }), clips[i].updatedAt == sent.updatedAt else { continue }
            clips[i].dirty = false
            store.put(clips[i])
        }
    }

    private func markGone(_ id: String) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        clips[i].cloudGone = true
        store.put(clips[i])
    }

    /// A deleted item goes for good once every side that has it has heard.
    private func reapTombstones() {
        for c in clips where c.deleted {
            let cloudDone = c.cloudGone == true || !cloud.configured
            let hubDone = !hubPaired || c.hubSig == Hub.signature(c) || (c.hubSig == nil && c.hubItem == nil)
            if cloudDone && hubDone {
                store.remove(c.id)
                clips.removeAll { $0.id == c.id }
            }
        }
    }

    // MARK: The wish hub

    func connectHub() async {
        hubConnecting = true
        defer { hubConnecting = false }
        do {
            secrets.hubToken = try await Hub.connect(hubSecret, deviceName: Host.current().localizedName ?? "Mac", transport: hubTransport)
            hubSecret = ""
            hubError = nil
            try secrets.save(paths.secrets)
            await syncHub()
        } catch { hubError = error.localizedDescription }
    }

    func disconnectHub() {
        secrets.hubToken = ""
        try? secrets.save(paths.secrets)
        store.setMeta("hub_cursor", "")
        hubError = nil
        lastHubSync = nil
    }

    /// Takes in what changed in the hub first, then sends what changed here, then reports what is saved.
    func syncHub() async {
        guard hubPaired, !hubSyncing else { return }
        hubSyncing = true
        defer { hubSyncing = false }
        do {
            try await pullHub()
            try await pushHub()
            try await reportSaved()
            reapTombstones()
            lastHubSync = Date()
            hubError = nil
        } catch { hubError = error.localizedDescription }
    }

    private func pullHub() async throws {
        let since = store.meta("hub_cursor").flatMap { $0.isEmpty ? nil : $0 }
        let got = try await Hub.pull(token: secrets.hubToken, since: since, transport: hubTransport)
        var added = false
        for item in got.items {
            guard let id = item["id"] as? String else { continue }
            let deleted = item["deleted"] as? Bool ?? false
            if let c = clip(id) {
                if c.deleted || c.hubUpdatedAt == item["updatedAt"] as? String { continue }
                if deleted {
                    change(id) { x in x.deleted = true; x.status = .saved; x.hubSig = nil; Hub.merge(item, into: &x); x.deleted = true }
                    purge(id)
                } else {
                    change(id) { Hub.merge(item, into: &$0) }
                }
            } else if !deleted, var c = Hub.clip(from: item) {
                c.dirty = true
                clips.append(c)
                store.put(c)
                added = true
            }
        }
        if let cursor = got.cursor { store.setMeta("hub_cursor", cursor) }
        if added { schedulePush(); runQueue() }
    }

    /// Images first: an item's screenshots must already be there when it lands.
    private func pushHub() async throws {
        for c in clips where !c.deleted && c.kind == .shots && (c.hubImages ?? []).isEmpty && !c.shotFiles.isEmpty {
            var ids: [String] = []
            for (i, name) in c.shotFiles.enumerated() {
                guard let jpeg = CloudAPI.webJPEG(paths.shotDir(c.id).appendingPathComponent(name), maxBase64: 3_900_000) else { throw CaptureError("截图压缩失败") }
                let id = String(format: "%@-%03d", c.id, i)
                try await Hub.putImage(token: secrets.hubToken, id: id, jpeg: jpeg, transport: hubTransport)
                ids.append(id)
            }
            if let n = clips.firstIndex(where: { $0.id == c.id }) { clips[n].hubImages = ids; store.put(clips[n]) }
        }
        let due = clips.filter { $0.hubSig != Hub.signature($0) && !($0.deleted && $0.hubSig == nil && $0.hubItem == nil) }
        for part in stride(from: 0, to: due.count, by: 100) {
            let chunk = Array(due[part..<min(part + 100, due.count)])
            let now = Date()
            let items = chunk.map { Hub.item(for: $0, now: now) }
            try await Hub.put(token: secrets.hubToken, items: items, transport: hubTransport)
            for (c, item) in zip(chunk, items) {
                guard let i = clips.firstIndex(where: { $0.id == c.id }) else { continue }
                clips[i].hubUpdatedAt = item["updatedAt"] as? String
                clips[i].hubSig = Hub.signature(c)
                if let d = try? JSONSerialization.data(withJSONObject: item) { clips[i].hubItem = String(data: d, encoding: .utf8) }
                store.put(clips[i])
            }
        }
    }

    private func reportSaved() async throws {
        let due = clips.filter { !$0.deleted && $0.status == .saved && $0.hasPDF && $0.hubFulfilled != true && $0.hubSig != nil }
        guard !due.isEmpty else { return }
        try await Hub.fulfill(token: secrets.hubToken, rows: due.map { Hub.fulfillRow($0) }, transport: hubTransport)
        for c in due {
            guard let i = clips.firstIndex(where: { $0.id == c.id }) else { continue }
            clips[i].hubFulfilled = true
            store.put(clips[i])
        }
    }

    /// Screenshots added on the hub page, read from its image store.
    private func fetchHubShots(_ c: Clip) async throws {
        guard let ids = c.hubImages, !ids.isEmpty else { return }
        guard hubPaired else { throw CaptureError("没有连接心愿中枢，读不到截图") }
        let dir = paths.shotDir(c.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var names: [String] = []
        for (i, id) in ids.enumerated() {
            guard let data = try await Hub.image(token: secrets.hubToken, id: id, transport: hubTransport) else { throw CaptureError("中枢里读不到截图，可能还没上传完") }
            let name = String(format: "%03d.jpg", i)
            try data.write(to: dir.appendingPathComponent(name))
            names.append(name)
        }
        change(c.id) { $0.shotFiles = names }
    }

    /// A long poll while awake: tells the web page the Mac is here, and returns at once when it has asked for something.
    func startCloudLink() {
        guard cloud.configured, link == nil else { return }
        link = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let r = try await self.cloud.call(["action": "mac_wait"], timeout: 90)
                    failures = 0
                    if r["web"] as? Bool == true { await self.sync() }
                } catch {
                    if Task.isCancelled { break }
                    failures += 1
                    try? await Task.sleep(for: .seconds(min(15 * failures, 120)))
                }
            }
        }
    }

    func stopCloudLink() { link?.cancel(); link = nil }

    func sayGoodbye(_ state: String, wait: Bool = false) {
        guard cloud.configured else { return }
        let api = cloud
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            _ = try? await api.call(["action": "mac_bye", "state": state], timeout: 3)
            done.signal()
        }
        if wait { _ = done.wait(timeout: .now() + 3) }
    }
}
