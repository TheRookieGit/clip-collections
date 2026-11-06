import Foundation

/// The wish hub's RPCs (my-collections on Supabase; the URL and publishable key are public and are in its page too).
/// The device token reaches only the 新闻 category. An item's state never goes in its JSON: mc_push overwrites whole
/// items by updatedAt, so 已保存 is reported through mc_fulfill.
public enum Hub {
    public static var url: String {
        #if DEBUG
        if let u = ProcessInfo.processInfo.environment["NEWS_TEST_HUB"] { return u }
        #endif
        return "https://lxicymhrzkuiqisuiotg.supabase.co"
    }
    static let key = "sb_publishable_KsJzV--VCz5k8WYQ-aqMLQ_rMgf-w9y"
    public static let apiVersion = 4
    public static let category = "news"
    static let webPage = "https://therookiegit.github.io/news-collections/"

    public struct Failure: LocalizedError {
        public let message: String
        public var code: String?
        public var errorDescription: String? { message }
    }

    /// (rpc name, arguments) → the decoded reply. Tests pass their own.
    public typealias Transport = (String, [String: Any]) async throws -> Any?

    public static let live: Transport = { name, args in
        var r = URLRequest(url: URL(string: "\(url)/rest/v1/rpc/\(name)")!)
        r.httpMethod = "POST"
        r.timeoutInterval = 60
        r.setValue(key, forHTTPHeaderField: "apikey")
        r.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: args)
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: r) } catch { throw Failure(message: "连不上心愿中枢，请检查网络。") }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let result = data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if status < 400 { return result is NSNull ? nil : result }
        if status >= 500 { throw Failure(message: "心愿中枢暂时不可用（HTTP \(status)）。") }
        let body = result as? [String: Any] ?? [:]
        let code = body["code"] as? String
        switch code {
        case "28000": throw Failure(message: "心愿中枢的配对已失效，请重新连接。", code: code)
        case "28P01": throw Failure(message: "同步密码不对。", code: code)
        case "MC429": throw Failure(message: "同步密码输错太多次，请 15 分钟后再试。", code: code)
        case "PGRST202", "22023": throw Failure(message: needsMigration, code: code)
        case "42501": throw Failure(message: "这个配对码不能读写「新闻」：请用同步密码重新连接。", code: code)
        default: throw Failure(message: "心愿中枢：\(body["message"] as? String ?? "HTTP \(status)")", code: code)
        }
    }

    static let needsMigration = "心愿中枢还没执行最新的数据库迁移（my-collections 的 009_newscollections.sql）。"

    /// Pairs with the hub's sync password: the hub makes a device token, which is kept; the password is not.
    /// A pairing code made on the hub page works too.
    public static func connect(_ secret: String, deviceName: String, transport: Transport = live) async throws -> String {
        let s = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if let v = try await transport("mc_api_version", [:]) as? Int, v < apiVersion { throw Failure(message: needsMigration) }
        if s.hasPrefix("mch_") {
            _ = try await transport("mc_wishes", ["p_token": s, "p_categories": [category], "p_since": NSNull()])
            return s
        }
        let reply = try await transport("mc_agent_create", ["p_pass": s, "p_name": deviceName, "p_app": "newscollections"]) as? [String: Any]
        guard let token = reply?["token"] as? String, token.hasPrefix("mch_") else { throw Failure(message: "心愿中枢没有给出配对码") }
        return token
    }

    public struct Pull { public var cursor: String?; public var items: [[String: Any]] }

    public static func pull(token: String, since: String?, transport: Transport) async throws -> Pull {
        let r = try await transport("mc_wishes", ["p_token": token, "p_categories": [category], "p_since": since ?? NSNull()]) as? [String: Any] ?? [:]
        let items = (r["items"] as? [[String: Any]] ?? []).filter { $0["category"] as? String == category }
        return Pull(cursor: r["cursor"] as? String, items: items)
    }

    public static func put(token: String, items: [[String: Any]], transport: Transport) async throws {
        _ = try await transport("mc_wish_put", ["p_token": token, "p_item": items])
    }

    public static func fulfill(token: String, rows: [[String: Any]], transport: Transport) async throws {
        _ = try await transport("mc_fulfill_put", ["p_token": token, "p_rows": rows])
    }

    public static func putImage(token: String, id: String, jpeg: Data, transport: Transport) async throws {
        _ = try await transport("mc_agent_put_image", ["p_token": token, "p_id": id, "p_data": "data:image/jpeg;base64," + jpeg.base64EncodedString()])
    }

    public static func image(token: String, id: String, transport: Transport) async throws -> Data? {
        guard let s = try await transport("mc_agent_get_image", ["p_token": token, "p_id": id]) as? String,
              let comma = s.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(s[s.index(after: comma)...]))
    }

    public static func fulfillRow(_ c: NewsItem, now: Date = Date()) -> [String: Any] {
        ["itemId": c.id, "ref": c.id, "url": webPage, "title": c.displayTitle, "ownedAt": NewsItem.iso(c.exportedAt ?? now)]
    }

    /// A new item from a hub entry, under the same id, so both sides name it alike.
    public static func newsItem(from item: [String: Any]) -> NewsItem? {
        guard let id = item["id"] as? String, id.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil else { return nil }
        let link = (item["link"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let shots = item["shots"] as? [String] ?? []
        let web = URL(string: link).map { (try? URLGuard.check($0)) != nil } ?? false
        var c = NewsItem(id: id, kind: !web && !shots.isEmpty ? .shots : .link, url: web ? link : "")
        c.hubImages = shots
        if let s = item["createdAt"] as? String, let d = date(s) { c.createdAt = d }
        merge(item, into: &c)
        if !web, shots.isEmpty {
            c.status = .failed
            c.reason = link.isEmpty ? "这条新闻没有链接或截图，无法保存" : "只支持公开的 http/https 链接"
        }
        return c
    }

    /// What the hub says about an item. What the user typed there counts as edited, so Claude does not replace it.
    public static func merge(_ item: [String: Any], into c: inout NewsItem) {
        let extra = item["extra"] as? [String: Any] ?? [:]
        if let t = item["title"] as? String, !t.isEmpty, t != c.url, t != c.title { c.title = t; c.titleEdited = true }
        if let n = item["note"] as? String { c.note = n }
        if let s = extra["source"] as? String { c.source = s }
        if let p = extra["published"] as? String { c.publishedAt = p }
        if let t = extra["topic"] as? String, t != c.topic { c.topic = t; c.topicEdited = !t.isEmpty }
        c.hubUpdatedAt = item["updatedAt"] as? String
        if let d = try? JSONSerialization.data(withJSONObject: item) { c.hubItem = String(data: d, encoding: .utf8) }
        c.hubSig = signature(c)
    }

    /// The hub item for this item, built on the last copy so fields this app does not know about survive.
    public static func item(for c: NewsItem, now: Date = Date()) -> [String: Any] {
        let stamp = NewsItem.iso(now)
        var out: [String: Any] = c.hubItem.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [
            "id": c.id, "category": category, "rating": 0, "createdAt": NewsItem.iso(c.createdAt), "links": [String](), "aliases": [String](),
            "done": false, "doneAt": NSNull(), "source": "newscollections", "externalIds": [String: Any](),
        ]
        out["title"] = c.displayTitle
        out["link"] = c.url
        out["note"] = c.note
        var extra = out["extra"] as? [String: Any] ?? [:]
        for (k, v) in [("source", c.source), ("published", c.publishedAt), ("topic", c.topic)] { if v.isEmpty { extra[k] = nil } else { extra[k] = v } }
        out["extra"] = extra
        if let ids = c.hubImages, !ids.isEmpty { out["shots"] = ids }
        if c.deleted { out["deleted"] = true }
        out["updatedAt"] = stamp
        return out
    }

    /// What the hub shows of a item. Status changes are not in it, so they send nothing.
    public static func signature(_ c: NewsItem) -> String {
        [c.displayTitle, c.url, c.note, c.source, c.publishedAt, c.topic, (c.hubImages ?? []).joined(separator: ","), "\(c.deleted)"].joined(separator: "\u{1f}")
    }

    public static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
