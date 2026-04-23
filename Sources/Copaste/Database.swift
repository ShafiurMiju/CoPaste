import Foundation
import SQLite3

struct Clip: Identifiable, Equatable {
    let id: Int64
    let text: String
    let createdAt: Date
    let pinned: Bool
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class Database {
    static let shared = Database()
    private var db: OpaquePointer?

    private init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Copaste", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("history.db").path

        if sqlite3_open(path, &db) != SQLITE_OK {
            fatalError("Copaste: failed to open database at \(path)")
        }

        exec("""
            CREATE TABLE IF NOT EXISTS clips (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                text TEXT NOT NULL UNIQUE,
                created_at INTEGER NOT NULL,
                pinned INTEGER NOT NULL DEFAULT 0,
                pinned_at INTEGER
            );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_clips_created ON clips(created_at DESC);")
        exec("CREATE INDEX IF NOT EXISTS idx_clips_pinned ON clips(pinned, pinned_at DESC);")
    }

    func insert(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let sql = """
            INSERT INTO clips (text, created_at) VALUES (?, ?)
            ON CONFLICT(text) DO UPDATE SET created_at = excluded.created_at;
        """
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, text, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, now)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)

        trim()
    }

    private func trim() {
        exec("""
            DELETE FROM clips
            WHERE pinned = 0
              AND id NOT IN (
                SELECT id FROM clips
                WHERE pinned = 0
                ORDER BY created_at DESC
                LIMIT 100
              );
        """)
    }

    func all() -> [Clip] {
        let sql = """
            SELECT id, text, created_at, pinned FROM clips
            ORDER BY pinned DESC,
                     CASE WHEN pinned = 1 THEN pinned_at ELSE created_at END DESC;
        """
        var stmt: OpaquePointer?
        var out: [Clip] = []
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let cText = sqlite3_column_text(stmt, 1)
            let text = cText != nil ? String(cString: cText!) : ""
            let created = sqlite3_column_int64(stmt, 2)
            let pinned = sqlite3_column_int(stmt, 3) != 0
            out.append(Clip(
                id: id,
                text: text,
                createdAt: Date(timeIntervalSince1970: Double(created) / 1000),
                pinned: pinned
            ))
        }
        sqlite3_finalize(stmt)
        return out
    }

    func togglePin(id: Int64) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let sql = """
            UPDATE clips
            SET pinned = 1 - pinned,
                pinned_at = CASE WHEN pinned = 0 THEN ? ELSE NULL END
            WHERE id = ?;
        """
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        sqlite3_bind_int64(stmt, 1, now)
        sqlite3_bind_int64(stmt, 2, id)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    func delete(id: Int64) {
        let sql = "DELETE FROM clips WHERE id = ? AND pinned = 0;"
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        sqlite3_bind_int64(stmt, 1, id)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    func clearUnpinned() {
        exec("DELETE FROM clips WHERE pinned = 0;")
    }

    enum MoveDirection { case up, down }

    /// Swaps the ordering value of `id` with its neighbor in the same section
    /// (pinned items reorder via pinned_at; unpinned via created_at).
    @discardableResult
    func move(id: Int64, direction: MoveDirection) -> Bool {
        let all = self.all()
        guard let idx = all.firstIndex(where: { $0.id == id }) else { return false }
        let clip = all[idx]
        let neighborIdx = direction == .up ? idx - 1 : idx + 1
        guard neighborIdx >= 0, neighborIdx < all.count else { return false }
        let neighbor = all[neighborIdx]
        guard clip.pinned == neighbor.pinned else { return false }

        let column = clip.pinned ? "pinned_at" : "created_at"
        guard
            let v1 = fetchInt64(column, id: clip.id),
            let v2 = fetchInt64(column, id: neighbor.id)
        else { return false }
        setInt64(column, id: clip.id, value: v2)
        setInt64(column, id: neighbor.id, value: v1)
        return true
    }

    private func fetchInt64(_ column: String, id: Int64) -> Int64? {
        let sql = "SELECT \(column) FROM clips WHERE id = ?;"
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        sqlite3_bind_int64(stmt, 1, id)
        var out: Int64?
        if sqlite3_step(stmt) == SQLITE_ROW {
            if sqlite3_column_type(stmt, 0) != SQLITE_NULL {
                out = sqlite3_column_int64(stmt, 0)
            }
        }
        sqlite3_finalize(stmt)
        return out
    }

    private func setInt64(_ column: String, id: Int64, value: Int64) {
        let sql = "UPDATE clips SET \(column) = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        sqlite3_bind_int64(stmt, 1, value)
        sqlite3_bind_int64(stmt, 2, id)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }
}
