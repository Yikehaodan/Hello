import Foundation
import SQLite3

struct DatabasePage<Item> {
    var items: [Item]
    var total: Int
}

struct DatabaseIndex {
    var date = Date.distantPast
    var category = ""
    var search = ""
    var position = 0
}

struct DatabaseFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// One private, embedded database. All access to a connection is serialized;
/// UI queries use a separate connection on a worker so they never hold the writer.
final class LocalDatabase: @unchecked Sendable {
    let url: URL
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(root: URL, name: String = "records.sqlite", readOnly: Bool = false) throws {
        url = root.appendingPathComponent(name)
        let fm = FileManager.default
        if !readOnly { try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        for path in [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")] {
            if let info = try? path.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]), info.isSymbolicLink == true || info.isRegularFile == false {
                throw DatabaseFailure(message: "本机数据库不是普通文件，已停止读取以保护数据。")
            }
        }
        if !readOnly && !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw DatabaseFailure(message: "无法创建本机数据库。")
            }
        }
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let message = failure().message; if let handle { sqlite3_close(handle) }; handle = nil
            throw DatabaseFailure(message: message)
        }
        do {
            sqlite3_busy_timeout(handle, 3000)
            if !readOnly {
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                try execute("PRAGMA journal_mode=WAL")
                try execute("PRAGMA synchronous=FULL")
                let version = try scalar("PRAGMA user_version")
                guard version <= 1 else { throw DatabaseFailure(message: "数据库版本较新，请使用新版 Hello 打开。") }
                try execute("CREATE TABLE IF NOT EXISTS records(kind TEXT NOT NULL,id TEXT NOT NULL,stamp REAL NOT NULL,category TEXT NOT NULL,search TEXT NOT NULL,position INTEGER NOT NULL,payload BLOB NOT NULL,PRIMARY KEY(kind,id))")
                try execute("CREATE INDEX IF NOT EXISTS records_date ON records(kind,stamp DESC,id)")
                try execute("CREATE INDEX IF NOT EXISTS records_position ON records(kind,position,id)")
                try execute("CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value BLOB NOT NULL)")
                try execute("PRAGMA user_version=1")
            }
        } catch { sqlite3_close(handle); handle = nil; throw error }
    }
    deinit { if let handle { sqlite3_close(handle) } }
    private func failure() -> DatabaseFailure {
        DatabaseFailure(message: "本机数据库操作失败：" + (handle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开"))
    }
    private func statement(_ sql: String, _ values: [String] = []) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &result, nil) == SQLITE_OK, let result else { throw failure() }
        for (index, value) in values.enumerated() { sqlite3_bind_text(result, Int32(index + 1), value, -1, transient) }
        return result
    }
    func execute(_ sql: String, _ values: [String] = []) throws {
        lock.lock(); defer { lock.unlock() }
        let statement = try statement(sql, values); defer { sqlite3_finalize(statement) }
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW { status = sqlite3_step(statement) }
        guard status == SQLITE_DONE else { throw failure() }
    }
    func scalar(_ sql: String, _ values: [String] = []) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let statement = try statement(sql, values); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return Int(sqlite3_column_int64(statement, 0))
    }
    /// Bounded numeric aggregates, never a growing list of event payloads.
    func integerRows(_ sql: String, _ values: [String] = [], limit: Int = 128) throws -> [[Int]] {
        lock.lock(); defer { lock.unlock() }
        let statement = try statement(sql, values); defer { sqlite3_finalize(statement) }
        var rows: [[Int]] = [], status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            guard rows.count < limit else { throw DatabaseFailure(message: "统计结果超出限制。") }
            rows.append((0..<sqlite3_column_count(statement)).map { Int(sqlite3_column_int64(statement, $0)) })
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw failure() }
        return rows
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        // An open SQLite handle can keep writing after its directory is moved.
        // Do not report a saved result if the configured path no longer owns it.
        var moved: Int32 = 0
        guard sqlite3_file_control(handle, "main", SQLITE_FCNTL_HAS_MOVED, &moved) == SQLITE_OK,
              moved == 0 else {
            throw DatabaseFailure(message: "数据库文件的位置已改变，本次更改未保存。请恢复原目录或重新打开应用。")
        }
        try execute("BEGIN IMMEDIATE")
        do { let result = try body(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
    func metadata<T: Decodable>(_ key: String, as: T.Type = T.self) throws -> T? {
        lock.lock(); defer { lock.unlock() }
        let statement = try statement("SELECT value FROM metadata WHERE key=?", [key]); defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw failure() }
        return try JSONDecoder().decode(T.self, from: blob(statement, 0))
    }
    func setMetadata<T: Encodable>(_ key: String, _ value: T) throws {
        lock.lock(); defer { lock.unlock() }
        let statement = try statement("INSERT INTO metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key])
        defer { sqlite3_finalize(statement) }
        let data = try JSONEncoder().encode(value)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(data.count), transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    /// Must run inside a transaction with the domain's metadata. Encode/write only changed rows.
    func sync<T: Codable & Equatable & Identifiable>(_ kind: String, old: [T], new: [T], ordered: Bool = false, index: (T, Int) -> DatabaseIndex) throws where T.ID == UUID {
        let previous = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        let positions = Dictionary(uniqueKeysWithValues: old.enumerated().map { ($0.element.id, $0.offset) })
        let ids = Set(new.map(\.id))
        guard ids.count == new.count else { throw DatabaseFailure(message: "记录编号重复，未保存。") }
        for item in old where !ids.contains(item.id) { try execute("DELETE FROM records WHERE kind=? AND id=?", [kind, item.id.uuidString]) }
        for (position, item) in new.enumerated() where previous[item.id] != item || (ordered && positions[item.id] != position) {
            let fields = index(item, position)
            let data = try JSONEncoder().encode(item)
            lock.lock(); defer { lock.unlock() }
            let statement = try statement("INSERT INTO records(kind,id,stamp,category,search,position,payload) VALUES(?,?,?,?,?,?,?) ON CONFLICT(kind,id) DO UPDATE SET stamp=excluded.stamp,category=excluded.category,search=excluded.search,position=excluded.position,payload=excluded.payload", [kind, item.id.uuidString])
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 3, fields.date.timeIntervalSince1970)
            sqlite3_bind_text(statement, 4, fields.category, -1, transient)
            sqlite3_bind_text(statement, 5, Self.normalized(fields.search), -1, transient)
            sqlite3_bind_int64(statement, 6, Int64(fields.position))
            _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 7, $0.baseAddress, Int32(data.count), transient) }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        }
    }
    func all<T: Decodable>(_ kind: String, orderedByPosition: Bool = true, as: T.Type = T.self) throws -> [T] {
        try page(kind, query: "", category: "all", offset: 0, limit: Int.max, orderedByPosition: orderedByPosition).items
    }
    func page<T: Decodable>(_ kind: String, query: String, category: String, offset: Int, limit: Int = 50, orderedByPosition: Bool = false) throws -> DatabasePage<T> {
        lock.lock(); defer { lock.unlock() }
        var predicate = "kind=?", values = [kind]
        if category != "all" { predicate += " AND category=?"; values.append(category) }
        if !query.isEmpty { predicate += " AND instr(search,?)>0"; values.append(Self.normalized(query)) }
        // A read transaction keeps the count and rows consistent during concurrent writes.
        try execute("BEGIN")
        do {
            let count = try scalar("SELECT count(*) FROM records WHERE " + predicate, values)
            let order = orderedByPosition ? "position,id" : "stamp DESC,id"
            let statement = try statement("SELECT payload FROM records WHERE " + predicate + " ORDER BY " + order + " LIMIT ? OFFSET ?", values + [String(max(0, limit)), String(max(0, offset))])
            defer { sqlite3_finalize(statement) }
            var items: [T] = []
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                items.append(try JSONDecoder().decode(T.self, from: blob(statement, 0)))
                status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else { throw failure() }
            try execute("COMMIT")
            return DatabasePage(items: items, total: count)
        } catch { try? execute("ROLLBACK"); throw error }
    }
    func readPage<T: Decodable & Sendable>(_ kind: String, query: String, category: String, offset: Int, orderedByPosition: Bool = false) async throws -> DatabasePage<T> {
        let url = url
        return try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let reader = try LocalDatabase(root: url.deletingLastPathComponent(), name: url.lastPathComponent, readOnly: true)
            return try reader.page(kind, query: query, category: category, offset: offset, orderedByPosition: orderedByPosition)
        }.value
    }
    private func blob(_ statement: OpaquePointer, _ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    static func backupLegacy(_ source: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return }
        let folder = source.deletingLastPathComponent().appendingPathComponent("MigrationBackups")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let backup = folder.appendingPathComponent(source.lastPathComponent)
        if !fm.fileExists(atPath: backup.path) {
            try fm.copyItem(at: source, to: backup)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
    }
}
