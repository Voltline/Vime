import Foundation
import CryptoKit
import SQLite3

/// SQLite work is isolated from the main thread. Transactions also serialize
/// different host apps' keyboard processes sharing the same App Group file.
actor ClipboardHistoryStore {
    struct Entry: Identifiable, Equatable, Sendable {
        let id: Int64
        let text: String
        let capturedAt: Date
    }
    static let lifetime: TimeInterval = 24 * 60 * 60
    static let maximumEntries = 100
    static let maximumTotalBytes = 1024 * 1024
    static let maximumTextBytes = 64 * 1024
    private let directory: URL?
    private var database: OpaquePointer?
    private enum Failure: Error { case database, invalidText }
    private enum Value { case text(String), integer(Int64), real(Double) }

    init(directory: URL? = nil, inMemory: Bool = false) {
        let root = directory ?? (FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KeyboardPreferences.appGroup)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
            .appendingPathComponent("Vime/Clipboard", isDirectory: true)
        self.directory = inMemory ? nil : root
    }

    /// Persist an attempt before asking iOS for text, including denied/empty
    /// reads. changeCount is scoped to a device boot, not to this process.
    func beginRead(version: Int, boot: String, at date: Date) throws -> Bool {
        try open()
        return try transaction {
            try prune(at: date)
            let query = try statement("SELECT attempt_version, boot FROM state WHERE id = 1")
            defer { sqlite3_finalize(query) }
            if sqlite3_step(query) == SQLITE_ROW,
               sqlite3_column_int64(query, 0) == Int64(version), string(query, 1) == boot { return false }
            try execute("INSERT INTO state(id, attempt_version, boot) VALUES(1, ?, ?) ON CONFLICT(id) DO UPDATE SET attempt_version=excluded.attempt_version, boot=excluded.boot",
                        [.integer(Int64(version)), .text(boot)])
            return true
        }
    }

    /// Only the immediately preceding text decides whether to offer a button.
    /// A -> B -> A offers A again, while history contains one recent A entry.
    func record(_ text: String?, version: Int, boot: String, at date: Date) throws -> Bool {
        if let text, !Self.accepts(text) { throw Failure.invalidText }
        try open()
        return try transaction {
            try prune(at: date)
            let query = try statement("SELECT fingerprint FROM state WHERE id=1 AND attempt_version=? AND boot=?",
                                      [.integer(Int64(version)), .text(boot)])
            let status = sqlite3_step(query)
            let previous = status == SQLITE_ROW ? string(query, 0) : nil
            sqlite3_finalize(query)
            guard status == SQLITE_ROW || status == SQLITE_DONE else { throw Failure.database }
            guard status == SQLITE_ROW else { return false }
            guard let text else {
                try execute("UPDATE state SET fingerprint=NULL WHERE id=1")
                return false
            }
            let fingerprint = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
            try execute("UPDATE state SET fingerprint=? WHERE id=1", [.text(fingerprint)])
            try execute("INSERT INTO history(fingerprint, text, bytes, captured) VALUES(?, ?, ?, ?) ON CONFLICT(fingerprint) DO UPDATE SET captured=excluded.captured",
                        [.text(fingerprint), .text(text), .integer(Int64(text.utf8.count)), .real(date.timeIntervalSince1970)])
            try prune(at: date)
            return previous != fingerprint
        }
    }

    func entries(at date: Date = Date()) throws -> [Entry] {
        try open()
        return try transaction {
            try prune(at: date)
            let query = try statement("SELECT id, text, captured FROM history ORDER BY captured DESC, id DESC")
            defer { sqlite3_finalize(query) }
            var values: [Entry] = []
            var status = sqlite3_step(query)
            while status == SQLITE_ROW {
                if let text = string(query, 1) {
                    values.append(.init(id: sqlite3_column_int64(query, 0), text: text,
                                        capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(query, 2))))
                }
                status = sqlite3_step(query)
            }
            guard status == SQLITE_DONE else { throw Failure.database }
            return values
        }
    }

    func text(for id: Int64, at date: Date = Date()) throws -> String? {
        try open()
        return try transaction {
            try prune(at: date)
            let query = try statement("SELECT text FROM history WHERE id=?", [.integer(id)])
            defer { sqlite3_finalize(query) }
            let status = sqlite3_step(query)
            guard status == SQLITE_ROW || status == SQLITE_DONE else { throw Failure.database }
            return status == SQLITE_ROW ? string(query, 0) : nil
        }
    }

    func removeExpired(at date: Date = Date()) throws {
        try open()
        try transaction { try prune(at: date) }
    }

    /// Clearing history must not make the unchanged system clipboard pop up.
    /// Opting out also erases the last-read metadata.
    func clear(includingReadState: Bool = false) throws {
        try open()
        try transaction {
            try execute("DELETE FROM history")
            if includingReadState { try execute("DELETE FROM state") }
        }
    }

    nonisolated static func accepts(_ text: String) -> Bool {
        text.utf8.prefix(maximumTextBytes + 1).count <= maximumTextBytes
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func open() throws {
        guard database == nil else { return }
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete, .posixPermissions: 0o700])
            var url = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        }
        let path = directory?.appendingPathComponent("history.sqlite").path ?? ":memory:"
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            throw Failure.database
        }
        database = handle
        do {
            sqlite3_busy_timeout(handle, 250)
            try execute("PRAGMA journal_mode=DELETE")
            try execute("PRAGMA secure_delete=ON")
            try execute("PRAGMA cache_size=-256")
            try execute("PRAGMA mmap_size=0")
            try execute("PRAGMA max_page_count=1024")
            try execute("CREATE TABLE IF NOT EXISTS state(id INTEGER PRIMARY KEY CHECK(id=1), attempt_version INTEGER, boot TEXT, fingerprint TEXT)")
            try execute("CREATE TABLE IF NOT EXISTS history(id INTEGER PRIMARY KEY AUTOINCREMENT, fingerprint TEXT NOT NULL UNIQUE, text TEXT NOT NULL, bytes INTEGER NOT NULL, captured REAL NOT NULL)")
            try execute("CREATE INDEX IF NOT EXISTS history_date ON history(captured, id)")
        } catch {
            sqlite3_close(handle); database = nil
            throw error
        }
    }

    private func prune(at date: Date) throws {
        let cutoff = date.timeIntervalSince1970 - Self.lifetime
        try execute("DELETE FROM history WHERE captured<=?", [.real(cutoff)])
        try execute("DELETE FROM history WHERE id NOT IN (SELECT id FROM history ORDER BY captured DESC, id DESC LIMIT ?)",
                    [.integer(Int64(Self.maximumEntries))])
        while true {
            let query = try statement("SELECT COALESCE(SUM(bytes), 0) FROM history")
            let status = sqlite3_step(query)
            let total = sqlite3_column_int64(query, 0)
            sqlite3_finalize(query)
            guard status == SQLITE_ROW else { throw Failure.database }
            if total <= Self.maximumTotalBytes { break }
            try execute("DELETE FROM history WHERE id=(SELECT id FROM history ORDER BY captured, id LIMIT 1)")
        }
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func statement(_ sql: String, _ values: [Value] = []) throws -> OpaquePointer {
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &query, nil) == SQLITE_OK, let query else { throw Failure.database }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let value):
                result = value.withCString { sqlite3_bind_text(query, index, $0, Int32(value.utf8.count), transient) }
            case .integer(let value): result = sqlite3_bind_int64(query, index, value)
            case .real(let value): result = sqlite3_bind_double(query, index, value)
            }
            if result != SQLITE_OK { sqlite3_finalize(query); throw Failure.database }
        }
        return query
    }

    private func execute(_ sql: String, _ values: [Value] = []) throws {
        let query = try statement(sql, values)
        defer { sqlite3_finalize(query) }
        var status = sqlite3_step(query)
        while status == SQLITE_ROW { status = sqlite3_step(query) }
        guard status == SQLITE_DONE else { throw Failure.database }
    }

    private func string(_ query: OpaquePointer, _ column: Int32) -> String? {
        guard let bytes = sqlite3_column_text(query, column) else { return nil }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(query, column))), as: UTF8.self)
    }

    deinit { if let database { sqlite3_close(database) } }
}
