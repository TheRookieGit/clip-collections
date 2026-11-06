import Foundation
import SQLite3

/// SQLite on this Mac, each item stored as JSON, so a new field needs no migration. Used from one actor only.
public final class NewsStore {
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(file: URL) throws {
        guard sqlite3_open(file.path, &db) == SQLITE_OK else { throw CaptureError("打不开数据库") }
        try exec("pragma journal_mode=wal")
        try exec("create table if not exists news(id text primary key, json text not null)")
        try exec("create table if not exists meta(key text primary key, value text not null)")
    }
    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CaptureError(String(cString: sqlite3_errmsg(db))) }
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    public func all() -> [NewsItem] {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, "select json from news", -1, &s, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(s) }
        var out: [NewsItem] = []
        while sqlite3_step(s) == SQLITE_ROW {
            guard let t = sqlite3_column_text(s, 0) else { continue }
            if let c = try? Self.decoder.decode(NewsItem.self, from: Data(String(cString: t).utf8)) { out.append(c) }
        }
        return out
    }

    public func put(_ c: NewsItem) {
        guard let data = try? Self.encoder.encode(c), let json = String(data: data, encoding: .utf8) else { return }
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, "insert into news(id,json) values(?,?) on conflict(id) do update set json=excluded.json", -1, &s, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_text(s, 1, c.id, -1, Self.transient)
        sqlite3_bind_text(s, 2, json, -1, Self.transient)
        sqlite3_step(s)
    }

    public func remove(_ id: String) {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, "delete from news where id=?", -1, &s, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_text(s, 1, id, -1, Self.transient)
        sqlite3_step(s)
    }

    public func meta(_ key: String) -> String? {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, "select value from meta where key=?", -1, &s, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_text(s, 1, key, -1, Self.transient)
        guard sqlite3_step(s) == SQLITE_ROW, let t = sqlite3_column_text(s, 0) else { return nil }
        return String(cString: t)
    }

    public func setMeta(_ key: String, _ value: String) {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, "insert into meta(key,value) values(?,?) on conflict(key) do update set value=excluded.value", -1, &s, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_text(s, 1, key, -1, Self.transient)
        sqlite3_bind_text(s, 2, value, -1, Self.transient)
        sqlite3_step(s)
    }
}
