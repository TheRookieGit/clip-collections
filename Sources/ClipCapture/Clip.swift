import Foundation

public enum ClipStatus: String, Codable, CaseIterable {
    case pending, processing, saved, incomplete, failed
    public var label: String {
        switch self {
        case .pending: return "待保存"
        case .processing: return "处理中"
        case .saved: return "已保存"
        case .incomplete: return "图片不全"
        case .failed: return "失败"
        }
    }
}

/// One saved news item. The Mac holds the whole of it; the cloud sees only `cloudRow`.
public struct Clip: Codable, Identifiable, Equatable {
    public enum Kind: String, Codable { case link, shots }

    public var id: String
    public var kind: Kind
    public var status: ClipStatus = .pending
    public var url = ""
    public var title = ""
    public var source = ""
    public var publishedAt = ""
    public var topic = ""
    public var note = ""
    public var reason = ""
    public var fullPage = false
    public var videoMissing = false
    public var expectedImages: Int?
    public var embeddedImages: Int?
    /// The titles and topics the user set stay; Claude only fills in what is empty.
    public var titleEdited = false
    public var topicEdited = false
    /// Local screenshot file names in shot order, under Paths.shots/<id>.
    public var shotFiles: [String] = []
    /// Cloud paths of the screenshots.
    public var cloudShots: [String] = []
    /// The app's own copy exists (Paths.pdf/<id>.pdf).
    public var hasPDF = false
    /// Sent to the desktop once. A copy the user later moved or deleted is never made again by itself.
    public var exportedAt: Date?
    public var desktopFile: String?
    public var createdAt: Date
    public var updatedAt: Date
    /// Needs telling the cloud.
    public var dirty = true
    /// Deleted here; kept as a tombstone until the cloud and the hub have heard.
    public var deleted = false

    // The wish hub. Optional, so items saved before pairing existed still load.
    /// The hub's whole item JSON, so its other fields survive an edit here.
    public var hubItem: String?
    public var hubUpdatedAt: String?
    /// What the hub last heard (Hub.signature). Differs from the current one: send it.
    public var hubSig: String?
    /// Screenshot ids in the hub's image store.
    public var hubImages: [String]?
    /// 已保存 has been reported.
    public var hubFulfilled: Bool?
    /// The cloud copy of a deleted item is gone.
    public var cloudGone: Bool?

    public init(id: String = Clip.newID(), kind: Kind, url: String = "", now: Date = Date()) {
        self.id = id; self.kind = kind; self.url = url; createdAt = now; updatedAt = now
    }

    public static func newID() -> String {
        String(Int(Date().timeIntervalSince1970 * 1000), radix: 36) + String((0..<6).map { _ in "0123456789abcdefghijklmnopqrstuvwxyz".randomElement()! })
    }

    public static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    public static func day(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    public var displayTitle: String {
        if !title.isEmpty { return title }
        return kind == .shots ? "截图 \(max(shotFiles.count, cloudShots.count)) 张" : url
    }

    public var cloudRow: [String: Any] {
        ["id": id, "kind": kind.rawValue, "status": status.rawValue, "url": url, "title": title, "source": source,
         "publishedAt": publishedAt, "topic": topic, "note": note, "reason": reason, "fullPage": fullPage,
         "videoMissing": videoMissing, "shots": cloudShots, "createdAt": Clip.iso(createdAt), "updatedAt": Clip.iso(updatedAt)]
    }
}

public struct Paths {
    public var root: URL
    public var desktop: URL
    public init(root: URL? = nil, desktop: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.root = root ?? home.appendingPathComponent("Library/Application Support/ClipCollections")
        self.desktop = desktop ?? home.appendingPathComponent("Desktop")
    }
    public var database: URL { root.appendingPathComponent("clips.sqlite") }
    public var secrets: URL { root.appendingPathComponent("secrets.json") }
    public var shots: URL { root.appendingPathComponent("shots") }
    public var pdfs: URL { root.appendingPathComponent("pdf") }
    public var work: URL { root.appendingPathComponent("work") }
    public func pdf(_ id: String) -> URL { pdfs.appendingPathComponent(id + ".pdf") }
    public func shotDir(_ id: String) -> URL { shots.appendingPathComponent(id) }
    public func ensure() throws {
        for d in [root, shots, pdfs, work] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    }
}

/// Kept in a file only this user can read. The API key never leaves the Mac except to the Claude API.
public struct Secrets: Codable, Equatable {
    public var anthropicKey = ""
    public var cloudPasscode = ""
    public var hubToken = ""
    public init() {}
    /// A field added later must not lose what a file from an earlier version holds.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        anthropicKey = try c.decodeIfPresent(String.self, forKey: .anthropicKey) ?? ""
        cloudPasscode = try c.decodeIfPresent(String.self, forKey: .cloudPasscode) ?? ""
        hubToken = try c.decodeIfPresent(String.self, forKey: .hubToken) ?? ""
    }
    public static func load(_ url: URL) -> Secrets {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Secrets.self, from: $0) } ?? Secrets()
    }
    public func save(_ url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// What a paste or a page's text means: the first web link in it. Share text from apps wraps the link in other words.
public enum LinkText {
    public static func firstURL(_ text: String) -> String? {
        guard let r = text.range(of: #"https?://[^\s<>"'，。！？）】》「」]+"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(text[r])
    }
}
