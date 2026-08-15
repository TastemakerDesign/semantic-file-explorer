import Foundation
import SQLite3

nonisolated final class IndexDatabase {
    enum Failure: LocalizedError {
        case sqlite(String)

        var errorDescription: String? {
            switch self {
            case .sqlite(let message): "Index database error: \(message)"
            }
        }
    }

    private static let schemaVersion: Int32 = 1

    private var handle: OpaquePointer?

    init(url: URL, dimension: Int) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let opened = sqlite3_open_v2(
            url.path(percentEncoded: false),
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        )
        guard opened == SQLITE_OK else {
            let message = lastMessage
            sqlite3_close_v2(handle)
            handle = nil
            throw Failure.sqlite(message)
        }
        try exec("PRAGMA journal_mode = WAL")
        try exec("PRAGMA synchronous = NORMAL")
        try exec("PRAGMA foreign_keys = ON")
        try createSchema()
        try dropVectors(notSized: dimension)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func entries() throws -> [IndexEntry] {
        let sql = """
            SELECT f.relative_path, f.modification_date, f.size, f.is_video, e.timestamp, e.vector
            FROM files f
            JOIN embeddings e ON e.file_id = f.id
            ORDER BY f.id, e.frame
            """
        var entries: [IndexEntry] = []
        var path = ""
        var modificationDate = Date.distantPast
        var size: Int64 = 0
        var isVideo = false
        var embeddings: [[Float]] = []
        var timestamps: [Double] = []

        func flush() {
            guard !embeddings.isEmpty else {
                return
            }
            entries.append(IndexEntry(
                relativePath: path,
                modificationDate: modificationDate,
                size: size,
                isVideo: isVideo,
                embeddings: embeddings,
                timestamps: timestamps
            ))
            embeddings = []
            timestamps = []
        }
        try withStatement(sql) { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                let row = String(cString: sqlite3_column_text(statement, 0))
                if row != path {
                    flush()
                    path = row
                }
                modificationDate = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
                size = sqlite3_column_int64(statement, 2)
                isVideo = sqlite3_column_int(statement, 3) != 0
                timestamps.append(sqlite3_column_double(statement, 4))
                embeddings.append(Self.vector(from: statement, column: 5))
            }
        }
        flush()
        return entries
    }

    func save(_ entries: [IndexEntry]) throws {
        guard !entries.isEmpty else {
            return
        }
        try transaction {
            try withStatement("DELETE FROM files WHERE relative_path = ?") { delete in
                try withStatement("INSERT INTO files (relative_path, modification_date, size, is_video) VALUES (?, ?, ?, ?)") { file in
                    try withStatement("INSERT INTO embeddings (file_id, frame, timestamp, vector) VALUES (?, ?, ?, ?)") { frame in
                        for entry in entries {
                            sqlite3_bind_text(delete, 1, entry.relativePath, -1, transientBytes)
                            try step(delete)
                            sqlite3_bind_text(file, 1, entry.relativePath, -1, transientBytes)
                            sqlite3_bind_double(file, 2, entry.modificationDate.timeIntervalSince1970)
                            sqlite3_bind_int64(file, 3, entry.size)
                            sqlite3_bind_int(file, 4, entry.isVideo ? 1 : 0)
                            try step(file)
                            let id = sqlite3_last_insert_rowid(handle)
                            for (index, embedding) in entry.embeddings.enumerated() {
                                sqlite3_bind_int64(frame, 1, id)
                                sqlite3_bind_int64(frame, 2, Int64(index))
                                sqlite3_bind_double(frame, 3, index < entry.timestamps.count ? entry.timestamps[index] : 0)
                                embedding.withUnsafeBufferPointer {
                                    _ = sqlite3_bind_blob(frame, 4, $0.baseAddress, Int32($0.count * MemoryLayout<Float>.size), transientBytes)
                                }
                                try step(frame)
                            }
                        }
                    }
                }
            }
        }
    }

    func remove(_ paths: some Collection<String>) throws {
        guard !paths.isEmpty else {
            return
        }
        try transaction {
            try withStatement("DELETE FROM files WHERE relative_path = ?") { statement in
                for path in paths {
                    sqlite3_bind_text(statement, 1, path, -1, transientBytes)
                    try step(statement)
                }
            }
        }
    }

    func removeFiles(notIn keeping: Set<String>) throws {
        var stored: Set<String> = []
        try withStatement("SELECT relative_path FROM files") { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                stored.insert(String(cString: sqlite3_column_text(statement, 0)))
            }
        }
        try remove(stored.subtracting(keeping))
    }

    func removeAll() throws {
        try exec("DELETE FROM files")
        try exec("VACUUM")
    }

    private func createSchema() throws {
        if try version() != Self.schemaVersion {
            try exec("DROP TABLE IF EXISTS embeddings")
            try exec("DROP TABLE IF EXISTS files")
        }
        try exec("""
            CREATE TABLE IF NOT EXISTS files (
                id INTEGER PRIMARY KEY,
                relative_path TEXT NOT NULL UNIQUE,
                modification_date REAL NOT NULL,
                size INTEGER NOT NULL,
                is_video INTEGER NOT NULL
            )
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS embeddings (
                file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                frame INTEGER NOT NULL,
                timestamp REAL NOT NULL,
                vector BLOB NOT NULL,
                PRIMARY KEY (file_id, frame)
            )
            """)
        try exec("PRAGMA user_version = \(Self.schemaVersion)")
    }

    private func dropVectors(notSized dimension: Int) throws {
        let width: Int? = try withStatement("SELECT length(vector) FROM embeddings LIMIT 1") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }
            return Int(sqlite3_column_int(statement, 0))
        }
        guard let width, width != dimension * MemoryLayout<Float>.size else {
            return
        }
        try exec("DELETE FROM files")
    }

    private func version() throws -> Int32 {
        try withStatement("PRAGMA user_version") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return 0
            }
            return sqlite3_column_int(statement, 0)
        }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure.sqlite(lastMessage)
        }

        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func step(_ statement: OpaquePointer) throws {
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }

        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw Failure.sqlite(lastMessage)
        }
    }

    private func exec(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            defer { sqlite3_free(message) }
            throw Failure.sqlite(message.map { String(cString: $0) } ?? lastMessage)
        }
    }

    private var lastMessage: String {
        guard let handle, let message = sqlite3_errmsg(handle) else {
            return "unknown error"
        }
        return String(cString: message)
    }

    private static func vector(from statement: OpaquePointer, column: Int32) -> [Float] {
        guard let bytes = sqlite3_column_blob(statement, column) else {
            return []
        }
        let count = Int(sqlite3_column_bytes(statement, column)) / MemoryLayout<Float>.size
        return [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
            memcpy(buffer.baseAddress, bytes, count * MemoryLayout<Float>.size)
            initialized = count
        }
    }
}

private nonisolated let transientBytes = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
