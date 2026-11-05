import AppKit
import ClipCapture
import SwiftUI
import UniformTypeIdentifiers

extension ClipStatus {
    var color: Color {
        switch self {
        case .pending: return .secondary
        case .processing: return .blue
        case .saved: return .green
        case .incomplete: return .orange
        case .failed: return .red
        }
    }
}

/// View state lives in observable classes rather than @State: Command Line Tools ship without the SwiftUI macro plugin.
@MainActor @Observable
final class MainState {
    var link = ""
    var query = ""
    var topic = ""
    var selection: String?
    var dropping = false
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

    private var shown: [Clip] {
        let q = ui.query.trimmingCharacters(in: .whitespaces).lowercased()
        return model.visible.filter { c in
            (ui.topic.isEmpty || c.topic == ui.topic)
                && (q.isEmpty || [c.title, c.source, c.url, c.topic, c.note].joined(separator: " ").lowercased().contains(q))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("粘贴新闻链接，或在窗口里按 ⌘V 粘贴图片", text: $ui.link)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("保存", action: save).keyboardShortcut(.defaultAction).disabled(ui.link.isEmpty)
            }
            .padding(12)
            if !model.draft.isEmpty { DraftTray(model: model) }
            if !model.hasKey { Banner(text: "还没填 Anthropic API Key：截图不会自动识别标题和主题。可以在设置（⌘,）里填写。") }
            if let e = model.cloudError { Banner(text: "云端同步出错：\(e)") }
            if let n = model.notice {
                Banner(text: n, onClose: { model.notice = nil })
            }
            HStack(spacing: 8) {
                TextField("搜索", text: $ui.query).textFieldStyle(.roundedBorder)
                Picker("主题", selection: $ui.topic) {
                    Text("全部主题").tag("")
                    ForEach(model.topics, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(maxWidth: 150)
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
            Divider()
            HSplitView {
                List(shown, selection: $ui.selection) { c in
                    Row(clip: c).tag(c.id)
                        .contextMenu { ClipActions(model: model, clip: c) }
                }
                .overlay { if shown.isEmpty { Text(model.visible.isEmpty ? "还没有新闻。粘贴一个链接或一张截图开始。" : "没有符合条件的新闻").foregroundStyle(.secondary) } }
                .frame(minWidth: 320)
                Group {
                    if let id = ui.selection, let c = model.clip(id), !c.deleted {
                        Detail(model: model, clip: c, ui: detail).id(id)
                    } else {
                        Text("选择一条新闻").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 300)
            }
        }
        .frame(minWidth: 680, minHeight: 460)
        .overlay { if ui.dropping { RoundedRectangle(cornerRadius: 8).stroke(.tint, lineWidth: 3).padding(4) } }
        .onDrop(of: [.fileURL], isTargeted: $ui.dropping) { items in
            for item in items {
                _ = item.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.addDropped([url]) } }
                }
            }
            return true
        }
    }

    private func save() { model.notice = nil; model.addLink(ui.link); if model.notice == nil { ui.link = "" } }
}

struct Banner: View {
    let text: String
    var onClose: (() -> Void)?
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let onClose { Button("知道了", action: onClose).buttonStyle(.link) }
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
    }
}

struct DraftTray: View {
    @Bindable var model: AppModel
    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(Array(model.draft.enumerated()), id: \.offset) { i, url in
                        if let img = NSImage(contentsOf: url) {
                            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).frame(width: 44, height: 44).clipped()
                                .overlay(alignment: .topTrailing) {
                                    Button { model.draft.remove(at: i) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("移除第 \(i + 1) 张")
                                }
                        }
                    }
                }
            }
            Button("存成一条新闻（\(model.draft.count) 张）") { model.saveDraft() }
            Button("清空") { model.draft = [] }
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
    }
}

struct Row: View {
    let clip: Clip
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(clip.displayTitle).lineLimit(2)
            HStack(spacing: 8) {
                Text(clip.status.label).foregroundStyle(clip.status.color).fontWeight(.medium)
                if clip.fullPage { Text("整页版") }
                if clip.videoMissing { Text("视频未保存") }
                if !clip.topic.isEmpty { Text(clip.topic) }
                if !clip.source.isEmpty { Text(clip.source).lineLimit(1) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

@MainActor @ViewBuilder
func clipButtons(_ model: AppModel, _ clip: Clip) -> some View {
    if clip.status == .failed || clip.status == .incomplete || clip.fullPage { Button("重试") { model.retry(clip.id) } }
    if clip.hasPDF {
        Button("打开 PDF") { model.openPDF(clip) }
        Button("在 Finder 中显示") { model.reveal(clip) }
    }
    if !clip.url.isEmpty { Button("打开原链接") { model.openOriginal(clip) } }
}

struct ClipActions: View {
    let model: AppModel, clip: Clip
    var body: some View {
        clipButtons(model, clip)
        Divider()
        if clip.hasPDF { Button("再导出一份到桌面") { model.exportAgain(clip.id) } }
        Button("删除") { model.delete(clip.id) }
    }
}

struct Detail: View {
    let model: AppModel
    let clip: Clip
    @Bindable var ui: DetailState

    private var changed: Bool { ui.title != clip.title || ui.topic != clip.topic || ui.note != clip.note }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(clip.status.label).foregroundStyle(clip.status.color).fontWeight(.semibold)
                    if clip.fullPage { Text("整页打印版").foregroundStyle(.secondary) }
                    Spacer()
                }
                if !clip.reason.isEmpty { Text(clip.reason).foregroundStyle(clip.status == .failed || clip.status == .incomplete ? .red : .secondary).textSelection(.enabled) }
                if let want = clip.expectedImages, clip.kind == .link { Text("图片 \(clip.embeddedImages ?? 0) / \(want) 张").font(.callout).foregroundStyle(.secondary) }
                if clip.videoMissing { Text("这是视频笔记：保留了封面和文字，视频本身没有保存。").font(.callout).foregroundStyle(.secondary) }
                if !clip.source.isEmpty { LabeledContent("来源", value: clip.source) }
                if !clip.publishedAt.isEmpty { LabeledContent("发布", value: clip.publishedAt) }
                if let f = clip.desktopFile { LabeledContent("桌面文件", value: URL(fileURLWithPath: f).lastPathComponent) }
                if !clip.url.isEmpty { Text(clip.url).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3) }
                Divider()
                TextField("标题", text: $ui.title).textFieldStyle(.roundedBorder)
                TextField("主题", text: $ui.topic).textFieldStyle(.roundedBorder)
                TextField("备注", text: $ui.note, axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder)
                if changed { Button("保存修改") { model.update(clip.id, title: ui.title, topic: ui.topic, note: ui.note) } }
                Divider()
                HStack { clipButtons(model, clip) }
                HStack {
                    if clip.hasPDF { Button("再导出一份到桌面") { model.exportAgain(clip.id) } }
                    Button("删除…", role: .destructive) { ui.confirming = true }
                }
            }
            .padding(14)
        }
        .onAppear(perform: load)
        .onChange(of: clip.title) { load() }
        .onChange(of: clip.topic) { load() }
        .alert("删除这条新闻？", isPresented: $ui.confirming) {
            Button("删除", role: .destructive) { model.delete(clip.id) }
            Button("取消", role: .cancel) {}
        } message: { Text("应用里的记录和副本会删除，桌面上的 PDF 不受影响。") }
    }

    private func load() { ui.title = clip.title; ui.topic = clip.topic; ui.note = clip.note }
}

@MainActor @Observable
final class SettingsState { var site = "https://www.xiaohongshu.com" }

struct SettingsView: View {
    @Bindable var model: AppModel
    @Bindable var ui: SettingsState

    var body: some View {
        Form {
            Section("Claude") {
                SecureField("Anthropic API Key", text: $model.secrets.anthropicKey)
                Text("只保存在这台 Mac 上，用来识别截图和建议主题。").font(.caption).foregroundStyle(.secondary)
            }
            Section("云端（网页版）") {
                TextField("地址", text: $model.cloudURL)
                SecureField("口令", text: $model.secrets.cloudPasscode)
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Section("心愿中枢（新闻分类）") {
                if model.hubPaired {
                    Text(hubStatus).font(.caption).foregroundStyle(model.hubError == nil ? Color.secondary : Color.red)
                    HStack {
                        Button("立即同步") { Task { await model.syncAll() } }
                        Button("断开") { model.disconnectHub() }
                    }
                } else {
                    SecureField("同步密码或配对码", text: $model.hubSecret)
                    Button(model.hubConnecting ? "连接中…" : "连接") { Task { await model.connectHub() } }
                        .disabled(model.hubSecret.trimmingCharacters(in: .whitespaces).isEmpty || model.hubConnecting)
                    Text(model.hubError ?? "同步密码只用来配对，不会保存。").font(.caption).foregroundStyle(model.hubError == nil ? Color.secondary : Color.red)
                }
            }
            Section("网站登录（可选）") {
                TextField("网址", text: $ui.site)
                Button("打开登录窗口") { LoginWindow.open(ui.site) }
                Text("大多数网站不用登录。付费站或被限制访问时，可以在这里登录一次。").font(.caption).foregroundStyle(.secondary)
            }
            Button("保存设置") { model.saveSecrets() }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 640)
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
