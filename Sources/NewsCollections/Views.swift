import AppKit
import NewsCapture
import SwiftUI
import UniformTypeIdentifiers

/// View state lives in observable classes rather than @State: Command Line Tools ship without the SwiftUI macro plugin.
@MainActor @Observable
final class MainState {
    var link = ""
    var query = ""
    var topic = ""
    var selection: String?
    var hovered: String?
    var dropping = false

    func shown(in model: AppModel) -> [NewsItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return model.visible.filter { c in
            (topic.isEmpty || c.topic == topic)
                && (q.isEmpty || [c.title, c.source, c.url, c.topic, c.note].joined(separator: " ").lowercased().contains(q))
        }
    }

    func move(by step: Int, in model: AppModel) {
        let list = shown(in: model)
        guard !list.isEmpty else { return }
        let at = list.firstIndex { $0.id == selection } ?? (step > 0 ? -1 : list.count)
        selection = list[min(max(at + step, 0), list.count - 1)].id
    }
}

@MainActor @Observable
final class DetailState {
    var title = ""
    var topic = ""
    var note = ""
    var confirming = false
}

struct MainView: View {
    @Bindable var model: AppModel
    @Bindable var ui: MainState
    let detail: DetailState

    /// Newest day first; a day keeps its items newest first.
    private var days: [(day: Date, newsItems: [NewsItem])] {
        let cal = Calendar.current
        var out: [(day: Date, newsItems: [NewsItem])] = []
        for c in ui.shown(in: model) {
            let d = cal.startOfDay(for: c.createdAt)
            if out.last?.day == d { out[out.count - 1].newsItems.append(c) } else { out.append((d, [c])) }
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            masthead
            intake
            if !model.draft.isEmpty { DraftTray(model: model) }
            notices
            filters
            Rule()
            HStack(spacing: 0) {
                list.frame(minWidth: 340, idealWidth: 400, maxWidth: 440)
                Rectangle().fill(Ink.line).frame(width: 1)
                detailPane.frame(minWidth: 320, maxWidth: .infinity)
            }
        }
        .background(Ink.paper)
        .foregroundStyle(Ink.text)
        .tint(Ink.seal)
        .frame(minWidth: 740, minHeight: 520)
        .overlay { if ui.dropping { Rectangle().strokeBorder(Ink.seal, style: StrokeStyle(lineWidth: 2, dash: [6, 4])).padding(6) } }
        .onDrop(of: [.fileURL], isTargeted: $ui.dropping) { items in
            for item in items {
                _ = item.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.addDropped([url]) } }
                }
            }
            return true
        }
    }

    private var masthead: some View {
        VStack(spacing: 8) {
            HStack(alignment: .lastTextBaseline, spacing: 12) {
                Text("News Collections").font(Type.heavy(34)).lineLimit(1).fixedSize()
                Spacer()
                Text(Dates.masthead()).font(Type.serif(13))
                Text("共 \(model.visible.count) 则").font(Type.serif(13)).foregroundStyle(Ink.soft)
            }
            DoubleRule()
        }
        .padding(.horizontal, 28).padding(.top, 30)
    }

    private var intake: some View {
        HStack(spacing: 12) {
            TextField("", text: $ui.link, prompt: Text("粘贴新闻链接，或按 ⌘V 放入截图").foregroundStyle(Ink.faint))
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .onSubmit(save)
                .accessibilityLabel("新闻链接")
            Button("剪存", action: save).buttonStyle(SealButton()).keyboardShortcut(.defaultAction).opacity(ui.link.isEmpty ? 0.45 : 1).disabled(ui.link.isEmpty)
        }
        .padding(.horizontal, 28).padding(.vertical, 12)
    }

    @ViewBuilder private var notices: some View {
        if !model.hasKey { Notice(text: "还没填 Anthropic API Key，截图不会自动识别标题和主题。可以在设置（⌘,）里填写。") }
        if let e = model.cloudError { Notice(text: "云端同步出错：\(e)") }
        if let e = model.hubError { Notice(text: "心愿中枢同步出错：\(e)") }
        if let n = model.notice { Notice(text: n, onClose: { model.notice = nil }) }
    }

    private var filters: some View {
        HStack(spacing: 16) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    topicTab("全部", "")
                    ForEach(model.topics, id: \.self) { topicTab($0, $0) }
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Ink.faint).accessibilityHidden(true)
                TextField("", text: $ui.query, prompt: Text("搜索").foregroundStyle(Ink.faint)).textFieldStyle(.plain).font(.system(size: 12.5)).frame(width: 130).accessibilityLabel("搜索")
            }
        }
        .padding(.horizontal, 28).padding(.bottom, 8)
    }

    private func topicTab(_ name: String, _ value: String) -> some View {
        let on = ui.topic == value
        return Button { ui.topic = value } label: {
            Text(name).font(on ? Type.title(13) : Type.serif(13)).foregroundStyle(on ? Ink.seal : Ink.soft)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(days, id: \.day) { group in
                    Text(Dates.heading(group.day)).font(Type.title(12)).kerning(1).foregroundStyle(Ink.soft)
                        .padding(.horizontal, 28).padding(.top, 18).padding(.bottom, 6)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(group.newsItems) { c in
                        Row(newsItem: c, selected: ui.selection == c.id, hovered: ui.hovered == c.id)
                            .contentShape(Rectangle())
                            .onTapGesture { ui.selection = c.id }
                            .onHover { ui.hovered = $0 ? c.id : (ui.hovered == c.id ? nil : ui.hovered) }
                            .contextMenu { NewsActions(model: model, newsItem: c) }
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .overlay { if ui.shown(in: model).isEmpty { EmptyList(filtered: !model.visible.isEmpty) } }
    }

    @ViewBuilder private var detailPane: some View {
        if let id = ui.selection, let c = model.newsItem(id), !c.deleted {
            Detail(model: model, newsItem: c, ui: detail).id(id)
        } else {
            VStack(spacing: 6) {
                Text("闻").font(Type.heavy(56)).foregroundStyle(Ink.line).accessibilityHidden(true)
                Text("选一则新闻").font(Type.serif(13)).foregroundStyle(Ink.faint)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func save() { model.notice = nil; model.addLink(ui.link); if model.notice == nil { ui.link = "" } }
}

struct EmptyList: View {
    let filtered: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(filtered ? "没有符合条件的新闻" : "剪下第一则新闻").font(Type.title(18))
            if !filtered {
                Text("粘贴链接，或者把截图按 ⌘V 放进来。\n存好的 PDF 会放到桌面。").font(.system(size: 12.5)).foregroundStyle(Ink.soft).lineSpacing(3)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct Notice: View {
    let text: String
    var onClose: (() -> Void)?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(text).font(.system(size: 12.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let onClose { Button("知道了", action: onClose).buttonStyle(TextAction(color: Ink.seal)) }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Ink.notice)
        .padding(.horizontal, 28).padding(.bottom, 10)
    }
}

struct DraftTray: View {
    @Bindable var model: AppModel
    var body: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(model.draft.enumerated()), id: \.offset) { i, url in
                        if let img = NSImage(contentsOf: url) {
                            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).frame(width: 40, height: 52).clipped()
                                .overlay(Rectangle().strokeBorder(Ink.line, lineWidth: 1))
                                .overlay(alignment: .topTrailing) {
                                    Button { model.draft.remove(at: i) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).padding(3).background(Ink.strong).foregroundStyle(Ink.paper) }
                                        .buttonStyle(.plain).accessibilityLabel("移除第 \(i + 1) 张")
                                }
                        }
                    }
                }
            }
            Button("合成一则（\(model.draft.count) 张）") { model.saveDraft() }.buttonStyle(SealButton())
            Button("清空") { model.draft = [] }.buttonStyle(TextAction())
        }
        .padding(.horizontal, 28).padding(.bottom, 12)
    }
}

struct Row: View {
    let newsItem: NewsItem
    var selected: Bool
    var hovered: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(newsItem.displayTitle)
                        .font(newsItem.title.isEmpty ? .system(size: 13) : Type.title(15))
                        .foregroundStyle(newsItem.title.isEmpty ? Ink.soft : Ink.text)
                        .lineLimit(2).lineSpacing(2)
                        .truncationMode(newsItem.title.isEmpty ? .middle : .tail)
                        .fixedSize(horizontal: false, vertical: true)
                    if !meta.isEmpty { Text(meta).font(.system(size: 11.5)).foregroundStyle(Ink.soft).lineLimit(1) }
                }
                Spacer(minLength: 0)
                Stamp(status: newsItem.status).padding(.top, 2)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(selected ? Ink.selected : hovered ? Ink.hover : .clear)
            Rule().padding(.horizontal, 16)
        }
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var meta: String {
        var p = [newsItem.topic, newsItem.source].filter { !$0.isEmpty }
        if newsItem.fullPage { p.append("整页版") }
        if newsItem.videoMissing { p.append("视频未保存") }
        return p.joined(separator: " · ")
    }
}

@MainActor @ViewBuilder
func newsButtons(_ model: AppModel, _ newsItem: NewsItem) -> some View {
    if newsItem.status == .failed || newsItem.status == .incomplete || newsItem.fullPage { Button("重试") { model.retry(newsItem.id) } }
    if newsItem.hasPDF {
        Button("打开 PDF") { model.openPDF(newsItem) }
        Button("在 Finder 中显示") { model.reveal(newsItem) }
    }
    if !newsItem.url.isEmpty { Button("打开原链接") { model.openOriginal(newsItem) } }
}

struct NewsActions: View {
    let model: AppModel, newsItem: NewsItem
    var body: some View {
        newsButtons(model, newsItem)
        Divider()
        if newsItem.hasPDF { Button("再导出一份到桌面") { model.exportAgain(newsItem.id) } }
        Button("删除") { model.delete(newsItem.id) }
    }
}

struct Detail: View {
    let model: AppModel
    let newsItem: NewsItem
    @Bindable var ui: DetailState

    private var changed: Bool { ui.title != newsItem.title || ui.topic != newsItem.topic || ui.note != newsItem.note }
    private var failing: Bool { newsItem.status == .failed || newsItem.status == .incomplete }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    Text(byline).font(.system(size: 12)).foregroundStyle(Ink.soft).lineLimit(1)
                    Spacer()
                    Stamp(status: newsItem.status, large: true)
                }
                TextField("", text: $ui.title, prompt: Text("标题待识别").foregroundStyle(Ink.faint), axis: .vertical)
                    .textFieldStyle(.plain).font(Type.title(23)).lineSpacing(5).lineLimit(1...6)
                    .padding(.top, 14)
                    .accessibilityLabel("标题")
                if !newsItem.reason.isEmpty { reason.padding(.top, 14) }
                actions.padding(.top, 18)
                VStack(alignment: .leading, spacing: 0) {
                    Rule()
                    field("主题") { TextField("", text: $ui.topic, prompt: Text("未分类").foregroundStyle(Ink.faint)).textFieldStyle(.plain).accessibilityLabel("主题") }
                    if let want = newsItem.expectedImages, newsItem.kind == .link, want > 0 { field("图片") { Text("\(newsItem.embeddedImages ?? 0) / \(want) 张") } }
                    if newsItem.kind == .shots { field("截图") { Text("\(max(newsItem.shotFiles.count, newsItem.cloudShots.count)) 张") } }
                    if newsItem.videoMissing { field("视频") { Text("没有保存，只保留了封面和文字").foregroundStyle(Ink.soft) } }
                    if let f = newsItem.desktopFile { field("桌面") { Text(URL(fileURLWithPath: f).lastPathComponent).lineLimit(2).textSelection(.enabled) } }
                    if !newsItem.url.isEmpty { field("原文") { Text(newsItem.url).foregroundStyle(Ink.soft).lineLimit(2).truncationMode(.middle).textSelection(.enabled) } }
                    field("备注") { TextField("", text: $ui.note, prompt: Text("写点什么").foregroundStyle(Ink.faint), axis: .vertical).textFieldStyle(.plain).lineLimit(1...6).accessibilityLabel("备注") }
                }
                .padding(.top, 22)
                if changed {
                    Button("保存修改") { model.update(newsItem.id, title: ui.title, topic: ui.topic, note: ui.note) }.buttonStyle(PlainAction()).padding(.top, 14)
                }
                HStack(spacing: 16) {
                    if newsItem.hasPDF { Button("再导出一份到桌面") { model.exportAgain(newsItem.id) }.buttonStyle(TextAction()) }
                    Button("删除") { ui.confirming = true }.buttonStyle(TextAction())
                }
                .padding(.top, 22)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 32)
        }
        .onAppear(perform: load)
        .onChange(of: newsItem.title) { load() }
        .onChange(of: newsItem.topic) { load() }
        .alert("删除这则新闻？", isPresented: $ui.confirming) {
            Button("删除", role: .destructive) { model.delete(newsItem.id) }
            Button("取消", role: .cancel) {}
        } message: { Text("应用里的记录和副本会删除，桌面上的 PDF 不受影响。") }
    }

    private var byline: String {
        let date = newsItem.publishedAt.isEmpty ? NewsItem.day(newsItem.createdAt) : newsItem.publishedAt
        return [newsItem.source, date, newsItem.fullPage ? "整页打印版" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var reason: some View {
        Text(newsItem.reason).font(.system(size: 12.5)).lineSpacing(3).textSelection(.enabled)
            .foregroundStyle(failing ? Ink.text : Ink.soft)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Ink.notice)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if failing || newsItem.fullPage { Button("重试") { model.retry(newsItem.id) }.buttonStyle(failing ? AnyActionStyle(SealButton()) : AnyActionStyle(PlainAction())) }
            if newsItem.hasPDF {
                Button("打开 PDF") { model.openPDF(newsItem) }.buttonStyle(failing ? AnyActionStyle(PlainAction()) : AnyActionStyle(SealButton()))
                Button("在 Finder 中显示") { model.reveal(newsItem) }.buttonStyle(PlainAction())
            }
            if !newsItem.url.isEmpty { Button("打开原链接") { model.openOriginal(newsItem) }.buttonStyle(PlainAction()) }
        }
    }

    private func field<V: View>(_ name: String, @ViewBuilder _ value: () -> V) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(name).font(Type.title(12)).foregroundStyle(Ink.soft).frame(width: 34, alignment: .leading)
                value().font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 9)
            Rule()
        }
    }

    private func load() { ui.title = newsItem.title; ui.topic = newsItem.topic; ui.note = newsItem.note }
}

struct AnyActionStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ s: S) { make = { AnyView(s.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

@MainActor @Observable
final class SettingsState { var site = "https://www.xiaohongshu.com" }

struct SettingsView: View {
    @Bindable var model: AppModel
    @Bindable var ui: SettingsState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("设置").font(Type.heavy(24)).kerning(2)
                    DoubleRule()
                }
                section("Claude", note: "只保存在这台 Mac 上，用来识别截图和建议主题。") {
                    row("API Key") { SecureField("", text: $model.secrets.anthropicKey).textFieldStyle(.plain) }
                }
                section("云端", note: status) {
                    row("地址") { TextField("", text: $model.cloudURL).textFieldStyle(.plain) }
                    row("口令") { SecureField("", text: $model.secrets.cloudPasscode).textFieldStyle(.plain) }
                }
                section("心愿中枢", note: model.hubPaired ? hubStatus : (model.hubError ?? "同步密码只用来配对，不会保存。")) {
                    if model.hubPaired {
                        HStack(spacing: 8) {
                            Button("立即同步") { Task { await model.syncAll() } }.buttonStyle(PlainAction())
                            Button("断开") { model.disconnectHub() }.buttonStyle(TextAction())
                        }
                        .padding(.vertical, 8)
                    } else {
                        row("密码") { SecureField("同步密码或配对码", text: $model.hubSecret).textFieldStyle(.plain) }
                        Button(model.hubConnecting ? "连接中…" : "连接") { Task { await model.connectHub() } }
                            .buttonStyle(PlainAction()).padding(.top, 8)
                            .disabled(model.hubSecret.trimmingCharacters(in: .whitespaces).isEmpty || model.hubConnecting)
                    }
                }
                section("网站登录", note: "大多数网站不用登录。付费站或被限制访问时，可以在这里登录一次。") {
                    row("网址") { TextField("", text: $ui.site).textFieldStyle(.plain) }
                    Button("打开登录窗口") { LoginWindow.open(ui.site) }.buttonStyle(PlainAction()).padding(.top, 8)
                }
                Button("保存设置") { model.saveSecrets() }.buttonStyle(SealButton()).padding(.top, 26)
            }
            .padding(.horizontal, 28).padding(.top, 34).padding(.bottom, 28)
        }
        .background(Ink.paper)
        .foregroundStyle(Ink.text)
        .frame(width: 500, height: 660)
    }

    private func section<V: View>(_ name: String, note: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(name).font(Type.title(14)).padding(.top, 22).padding(.bottom, 6)
            Rule()
            content()
            Text(note).font(.system(size: 11.5)).foregroundStyle(Ink.soft).lineSpacing(2).padding(.top, 7).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row<V: View>(_ name: String, @ViewBuilder _ value: () -> V) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text(name).font(.system(size: 12.5)).foregroundStyle(Ink.soft).frame(width: 52, alignment: .leading)
                value().font(.system(size: 13))
            }
            .padding(.vertical, 8)
            Rule()
        }
    }

    private var hubStatus: String {
        if let e = model.hubError { return "出错：\(e)" }
        return model.lastHubSync.map { "已连接，上次同步：\($0.formatted(date: .omitted, time: .shortened))" } ?? "已连接"
    }

    private var status: String {
        if let e = model.cloudError { return "出错：\(e)" }
        return model.lastCloudSync.map { "上次同步：\($0.formatted(date: .omitted, time: .shortened))" } ?? "尚未同步"
    }
}
