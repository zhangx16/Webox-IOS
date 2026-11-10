//
//  Store.swift
//  WeBox for iOS
//
//  SQLite backed persistence for sources, favorites, progress, downloads and the
//  script key/value + shared cache namespaces exposed to JavaScript.
//

import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

final class Store {
    static let shared = Store()

    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "webox.store")

    private init() {
        let path = Files.root.appendingPathComponent("webox.sqlite").path
        if sqlite3_open(path, &handle) != SQLITE_OK {
            Log.shared.error("无法打开数据库：\(sqlite3_errmsg(handle).map { String(cString: $0) } ?? "unknown")")
            return
        }
        sqlite3_busy_timeout(handle, 3000)
        execute("PRAGMA journal_mode=WAL;")
        execute("""
        CREATE TABLE IF NOT EXISTS objects (
            kind TEXT NOT NULL,
            id TEXT NOT NULL,
            json TEXT,
            num REAL DEFAULT 0,
            expires REAL DEFAULT 0,
            PRIMARY KEY (kind, id)
        );
        """)
        execute("CREATE INDEX IF NOT EXISTS idx_objects_kind ON objects(kind, num DESC);")
    }

    deinit {
        sqlite3_close(handle)
    }

    // MARK: - Primitives

    private func execute(_ sql: String) {
        sqlite3_exec(handle, sql, nil, nil, nil)
    }

    private func bind(_ statement: OpaquePointer?, _ values: [Any?]) {
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case nil:
                sqlite3_bind_null(statement, position)
            case let text as String:
                sqlite3_bind_text(statement, position, text, -1, SQLITE_TRANSIENT)
            case let number as Int:
                sqlite3_bind_int64(statement, position, Int64(number))
            case let number as Int64:
                sqlite3_bind_int64(statement, position, number)
            case let number as Double:
                sqlite3_bind_double(statement, position, number)
            case let date as Date:
                sqlite3_bind_double(statement, position, date.timeIntervalSince1970)
            default:
                sqlite3_bind_text(statement, position, String(describing: value!), -1, SQLITE_TRANSIENT)
            }
        }
    }

    private func query(_ sql: String, _ values: [Any?] = [], row: (OpaquePointer?) -> Void) {
        queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                Log.shared.error("SQL 准备失败：\(String(cString: sqlite3_errmsg(handle))) — \(sql)")
                return
            }
            defer { sqlite3_finalize(statement) }
            bind(statement, values)
            while sqlite3_step(statement) == SQLITE_ROW {
                row(statement)
            }
        }
    }

    private func run(_ sql: String, _ values: [Any?] = []) {
        queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                Log.shared.error("SQL 执行失败：\(String(cString: sqlite3_errmsg(handle))) — \(sql)")
                return
            }
            defer { sqlite3_finalize(statement) }
            bind(statement, values)
            if sqlite3_step(statement) != SQLITE_DONE {
                Log.shared.error("SQL 写入失败：\(String(cString: sqlite3_errmsg(handle))) — \(sql)")
            }
        }
    }

    private func string(_ statement: OpaquePointer?, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    // MARK: - Generic objects

    func put(kind: String, id: String, json: String, num: Double = 0, expires: Double = 0) {
        run("INSERT OR REPLACE INTO objects(kind, id, json, num, expires) VALUES(?,?,?,?,?);",
            [kind, id, json, num, expires])
    }

    func get(kind: String, id: String) -> String? {
        var result: String?
        query("SELECT json FROM objects WHERE kind=? AND id=?;", [kind, id]) { statement in
            result = self.string(statement, 0)
        }
        return result
    }

    func all(kind: String) -> [(id: String, json: String, num: Double)] {
        var result: [(String, String, Double)] = []
        query("SELECT id, json, num FROM objects WHERE kind=? ORDER BY num DESC;", [kind]) { statement in
            result.append((self.string(statement, 0), self.string(statement, 1), sqlite3_column_double(statement, 2)))
        }
        return result
    }

    func remove(kind: String, id: String) {
        run("DELETE FROM objects WHERE kind=? AND id=?;", [kind, id])
    }

    func removeAll(kind: String) {
        run("DELETE FROM objects WHERE kind=?;", [kind])
    }

    func removeExpired() {
        run("DELETE FROM objects WHERE expires > 0 AND expires < ?;", [Date().timeIntervalSince1970])
    }

    // MARK: - Script bridge: private storage and shared cache

    func scriptGet(_ namespace: String, key: String) -> String? {
        get(kind: "kv.\(namespace)", id: key)
    }

    func scriptSet(_ namespace: String, key: String, value: String) {
        put(kind: "kv.\(namespace)", id: key, json: value)
    }

    func scriptRemove(_ namespace: String, key: String) {
        remove(kind: "kv.\(namespace)", id: key)
    }

    func scriptKeys(_ namespace: String) -> [String] {
        all(kind: "kv.\(namespace)").map(\.id)
    }

    func scriptClear(_ namespace: String) {
        removeAll(kind: "kv.\(namespace)")
    }

    func sharedGet(_ namespace: String, key: String) -> String? {
        var value: String?
        query("SELECT json FROM objects WHERE kind=? AND id=? AND (expires = 0 OR expires > ?);",
              ["shared.\(namespace)", key, Date().timeIntervalSince1970]) { statement in
            value = self.string(statement, 0)
        }
        return value
    }

    func sharedSet(_ namespace: String, key: String, value: String, ttl: TimeInterval) {
        let expires = ttl > 0 ? Date().timeIntervalSince1970 + ttl : 0
        put(kind: "shared.\(namespace)", id: key, json: value, expires: expires)
    }

    func sharedKeys(_ namespace: String) -> [String] {
        var result: [String] = []
        query("SELECT id FROM objects WHERE kind=? AND (expires = 0 OR expires > ?);",
              ["shared.\(namespace)", Date().timeIntervalSince1970]) { statement in
            result.append(self.string(statement, 0))
        }
        return result
    }

    func sharedRemove(_ namespace: String, key: String) {
        remove(kind: "shared.\(namespace)", id: key)
    }
}
