import Foundation
import SQLite3

/// Minimal read-only SQLite access over the system `libsqlite3`.
///
/// Several desktop apps (Cursor, VS Code forks) keep their signed-in session
/// in a `state.vscdb`, which is an ordinary SQLite file. Reading it needs no
/// keychain prompt and no third-party dependency — just a single-column
/// lookup, which is all this wraps.
enum SQLiteRead {
    /// SQLite wants this sentinel to mark a transient string it must copy.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Opens `path` read-only and returns the first column of the first row,
    /// for a query bound with a single text parameter. nil on any failure —
    /// a locked or absent database must degrade, never throw.
    static func firstString(inFile path: String, query: String, bind: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        var db: OpaquePointer?
        // A live app holds a write lock; open read-only and over the immutable
        // URI so a WAL-mode file opens without needing its sidecar files.
        let uri = "file:\(path)?immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, bind, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0)
        else { return nil }
        return String(cString: raw)
    }
}
