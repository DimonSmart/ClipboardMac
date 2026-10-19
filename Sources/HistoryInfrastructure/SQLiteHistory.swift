import Foundation
import CryptoKit
import CSQLite
import HistoryCore

public struct StorageError: Error, LocalizedError, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public actor SQLiteHistory: HistoryRepository {
    // Only this actor accesses the connection. The wrapper closes it on final release.
    private final class Connection: @unchecked Sendable {
        let handle: OpaquePointer
        init(_ handle: OpaquePointer) { self.handle = handle }
        deinit { sqlite3_close(handle) }
    }
    private let connection: Connection
    public let path: String
    private var db: OpaquePointer { connection.handle }
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        self.path = path
        if path != ":memory:" {
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw StorageError(message: "Could not open local history database.")
        }
        connection = Connection(pointer)
        sqlite3_busy_timeout(pointer, 1500)
        func execute(_ sql: String) throws {
            guard sqlite3_exec(pointer, sql, nil, nil, nil) == SQLITE_OK else { throw StorageError(message: "History database initialization failed (\(sqlite3_errcode(pointer))).") }
        }
        try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA secure_delete=ON;")
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(pointer, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else { throw StorageError(message: "Cannot read database version.") }
        let version = sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : -1
        sqlite3_finalize(statement)
        guard version == 0 || version == 1 else { throw StorageError(message: "This history database requires a newer application.") }
        if version == 0 {
            try execute("BEGIN IMMEDIATE; CREATE TABLE history (id TEXT PRIMARY KEY, content BLOB NOT NULL, digest BLOB NOT NULL, created REAL NOT NULL, copied REAL NOT NULL, source TEXT, pinned REAL); CREATE INDEX history_digest ON history(digest); CREATE INDEX history_recent ON history(pinned, copied); PRAGMA user_version=1; COMMIT;")
        }
        if path != ":memory:" { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path) }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func failure() -> StorageError { StorageError(message: "Local history operation failed (SQLite \(sqlite3_errcode(db))).") }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &result, nil) == SQLITE_OK, let result else { throw failure() }
        return result
    }
    private func bind(_ text: String, at index: Int32, to stmt: OpaquePointer) {
        _ = text.withCString { sqlite3_bind_text(stmt, index, $0, Int32(text.utf8.count), transient) }
    }
    private func bind(_ bytes: Data, at index: Int32, to stmt: OpaquePointer) {
        _ = bytes.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(bytes.count), transient) }
    }
    private func finish(_ stmt: OpaquePointer) throws { guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() } }
    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch {
            let original = error
            guard sqlite3_exec(db, "ROLLBACK", nil, nil, nil) == SQLITE_OK else { throw StorageError(message: "Local history rollback failed. Restart the application.") }
            throw original
        }
    }
    private func prune(_ limit: Int) throws {
        let stmt = try statement("DELETE FROM history WHERE id IN (SELECT id FROM history WHERE pinned IS NULL ORDER BY copied DESC, id ASC LIMIT -1 OFFSET ?)")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(HistoryRules.limit(limit)))
        try finish(stmt)
    }
    public func record(_ text: String, source: String?, at: Date, limit: Int) throws {
        guard HistoryRules.eligible(text) else { return }
        let bytes = Data(text.utf8), hash = Data(SHA256.hash(data: Data(text.utf8)))
        try transaction {
            let lookup = try statement("SELECT id FROM history WHERE digest=? AND content=? LIMIT 1")
            defer { sqlite3_finalize(lookup) }
            bind(hash, at: 1, to: lookup); bind(bytes, at: 2, to: lookup)
            let step = sqlite3_step(lookup)
            guard step == SQLITE_ROW || step == SQLITE_DONE else { throw failure() }
            let existing = step == SQLITE_ROW ? String(cString: sqlite3_column_text(lookup, 0)) : nil
            let stmt = try statement(existing == nil
                ? "INSERT INTO history (id,content,digest,created,copied,source) VALUES (?,?,?,?,?,?)"
                : "UPDATE history SET content=?,digest=?,created=created,copied=?,source=COALESCE(?,source) WHERE id=?")
            defer { sqlite3_finalize(stmt) }
            if let existing {
                bind(bytes, at: 1, to: stmt); bind(hash, at: 2, to: stmt)
                sqlite3_bind_double(stmt, 3, at.timeIntervalSince1970)
                if let source { bind(source, at: 4, to: stmt) }
                bind(existing, at: 5, to: stmt)
            } else {
                bind(UUID().uuidString, at: 1, to: stmt); bind(bytes, at: 2, to: stmt); bind(hash, at: 3, to: stmt)
                sqlite3_bind_double(stmt, 4, at.timeIntervalSince1970); sqlite3_bind_double(stmt, 5, at.timeIntervalSince1970)
                if let source { bind(source, at: 6, to: stmt) }
            }
            try finish(stmt); try prune(limit)
        }
    }
    public func entries() throws -> [HistoryEntry] {
        let stmt = try statement("SELECT id,content,created,copied,source,pinned FROM history")
        defer { sqlite3_finalize(stmt) }
        var result: [HistoryEntry] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { return HistoryRules.display(result, query: "") }
            guard step == SQLITE_ROW, let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))) else { throw failure() }
            let count = Int(sqlite3_column_bytes(stmt, 1))
            guard let data = sqlite3_column_blob(stmt, 1), let text = String(data: Data(bytes: data, count: count), encoding: .utf8) else { throw failure() }
            let source = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 4))
            let pin = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
            result.append(HistoryEntry(id: id, text: text, createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)), copiedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)), source: source, pinnedAt: pin))
        }
    }
    public func setPinned(_ id: UUID, pinned: Bool, at: Date, limit: Int) throws {
        try transaction {
            let stmt = try statement("UPDATE history SET pinned=? WHERE id=?")
            defer { sqlite3_finalize(stmt) }
            if pinned { sqlite3_bind_double(stmt, 1, at.timeIntervalSince1970) }
            bind(id.uuidString, at: 2, to: stmt); try finish(stmt); try prune(limit)
        }
    }
    public func delete(_ id: UUID) throws {
        try transaction {
            let stmt = try statement("DELETE FROM history WHERE id=?")
            defer { sqlite3_finalize(stmt) }
            bind(id.uuidString, at: 1, to: stmt); try finish(stmt)
        }
    }
    public func clear(includingPins: Bool) throws {
        try transaction { try execute(includingPins ? "DELETE FROM history" : "DELETE FROM history WHERE pinned IS NULL") }
    }
    public func applyLimit(_ limit: Int) throws { try transaction { try prune(limit) } }
    public func maintain() throws {
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try execute("VACUUM")
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }
}
