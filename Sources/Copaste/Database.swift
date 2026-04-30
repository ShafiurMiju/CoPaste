import Foundation
import SQLite3
import AppKit
import CryptoKit

enum ClipKind: Int {
    case text = 0
    case image = 1
}

struct Clip: Identifiable, Equatable {
    let id: Int64
    let kind: ClipKind
    let text: String
    let imagePath: String?
    let thumbnail: Data?
    let imageWidth: Int
    let imageHeight: Int
    let imageBytes: Int64
    let createdAt: Date
    let pinned: Bool
    let pinnedAt: Date?
    let isPassword: Bool
}

struct ClipGroup: Identifiable, Equatable, Hashable {
    let id: Int64
    let name: String
    let createdAt: Date
    let itemCount: Int
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class Database {
    static let shared = Database()
    private var db: OpaquePointer?
    private let imagesDir: URL

    static let textHistoryLimit = 100
    static let imageHistoryLimit = 30
    static let maxImageBytes: Int64 = 20 * 1024 * 1024  // 20 MB
    static let thumbnailMaxDim: CGFloat = 200

    private init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Copaste", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        self.imagesDir = dir.appendingPathComponent("images", isDirectory: true)
        try? fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)

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

        // Image columns — added lazily for upgrades from text-only schema.
        addColumnIfMissing("kind", type: "INTEGER NOT NULL DEFAULT 0")
        addColumnIfMissing("image_path", type: "TEXT")
        addColumnIfMissing("thumbnail", type: "BLOB")
        addColumnIfMissing("image_width", type: "INTEGER NOT NULL DEFAULT 0")
        addColumnIfMissing("image_height", type: "INTEGER NOT NULL DEFAULT 0")
        addColumnIfMissing("image_bytes", type: "INTEGER NOT NULL DEFAULT 0")
        addColumnIfMissing("is_password", type: "INTEGER NOT NULL DEFAULT 0")
        exec("CREATE INDEX IF NOT EXISTS idx_clips_kind ON clips(kind);")

        exec("PRAGMA foreign_keys = ON;")
        exec("""
            CREATE TABLE IF NOT EXISTS groups (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL UNIQUE,
                created_at INTEGER NOT NULL
            );
        """)
        exec("""
            CREATE TABLE IF NOT EXISTS group_clips (
                group_id INTEGER NOT NULL,
                clip_id INTEGER NOT NULL,
                added_at INTEGER NOT NULL,
                PRIMARY KEY (group_id, clip_id),
                FOREIGN KEY (group_id) REFERENCES groups(id) ON DELETE CASCADE,
                FOREIGN KEY (clip_id)  REFERENCES clips(id)  ON DELETE CASCADE
            );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_group_clips_group ON group_clips(group_id);")
        exec("CREATE INDEX IF NOT EXISTS idx_group_clips_clip  ON group_clips(clip_id);")
    }

    private func addColumnIfMissing(_ name: String, type: String) {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "PRAGMA table_info(clips);", -1, &stmt, nil)
        var exists = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cName = sqlite3_column_text(stmt, 1),
               String(cString: cName) == name {
                exists = true
                break
            }
        }
        sqlite3_finalize(stmt)
        if !exists {
            exec("ALTER TABLE clips ADD COLUMN \(name) \(type);")
        }
    }

    // MARK: - Insert (text)

    func insert(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let sql = """
            INSERT INTO clips (text, created_at, kind) VALUES (?, ?, 0)
            ON CONFLICT(text) DO UPDATE SET created_at = excluded.created_at;
        """
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, text, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, now)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)

        trimText()
    }

    // MARK: - Insert (image)

    /// Stores an image clip. The full bytes are written to a file on disk
    /// (named by SHA256 hash for free dedup); a small thumbnail is kept in
    /// the DB for fast list rendering.
    func insertImage(_ data: Data) {
        guard !data.isEmpty else { return }
        guard Int64(data.count) <= Self.maxImageBytes else {
            NSLog("[Copaste] image too large (\(data.count) bytes), skipping")
            return
        }

        let hash = sha256Hex(data)
        let key = "image:\(hash)"
        let filename = "\(hash).png"
        let fileURL = imagesDir.appendingPathComponent(filename)

        // Convert whatever bitmap we got (TIFF/PNG) into PNG and write to disk.
        guard let pngData = pngEncode(data) else {
            NSLog("[Copaste] failed to encode image as PNG")
            return
        }

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                try pngData.write(to: fileURL, options: .atomic)
            } catch {
                NSLog("[Copaste] failed to write image: \(error)")
                return
            }
        }

        let (w, h) = imageDimensions(pngData)
        let thumb = makeThumbnail(pngData)
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        let sql = """
            INSERT INTO clips (text, created_at, kind, image_path, thumbnail, image_width, image_height, image_bytes)
            VALUES (?, ?, 1, ?, ?, ?, ?, ?)
            ON CONFLICT(text) DO UPDATE SET created_at = excluded.created_at;
        """
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, now)
        sqlite3_bind_text(stmt, 3, filename, -1, SQLITE_TRANSIENT)
        if let thumb {
            thumb.withUnsafeBytes { raw in
                _ = sqlite3_bind_blob(stmt, 4, raw.baseAddress, Int32(thumb.count), SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        sqlite3_bind_int(stmt, 5, Int32(w))
        sqlite3_bind_int(stmt, 6, Int32(h))
        sqlite3_bind_int64(stmt, 7, Int64(pngData.count))
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)

        trimImages()
    }

    private func trimText() {
        // Group membership does NOT protect from trim — only pinning does.
        // Removing a clip cascades to delete its group_clips rows.
        exec("""
            DELETE FROM clips
            WHERE pinned = 0 AND kind = 0
              AND id NOT IN (
                SELECT id FROM clips
                WHERE pinned = 0 AND kind = 0
                ORDER BY created_at DESC
                LIMIT \(Self.textHistoryLimit)
              );
        """)
    }

    private func trimImages() {
        // Group membership does NOT protect from trim — only pinning does.
        // Removing a clip cascades to delete its group_clips rows.
        let findSQL = """
            SELECT id, image_path FROM clips
            WHERE pinned = 0 AND kind = 1
              AND id NOT IN (
                SELECT id FROM clips
                WHERE pinned = 0 AND kind = 1
                ORDER BY created_at DESC
                LIMIT \(Self.imageHistoryLimit)
              );
        """
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, findSQL, -1, &stmt, nil)
        var doomed: [(Int64, String?)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let path: String? = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            doomed.append((id, path))
        }
        sqlite3_finalize(stmt)

        for (_, path) in doomed {
            unlinkImageIfUnreferenced(path: path, excludingID: nil)
        }

        exec("""
            DELETE FROM clips
            WHERE pinned = 0 AND kind = 1
              AND id NOT IN (
                SELECT id FROM clips
                WHERE pinned = 0 AND kind = 1
                ORDER BY created_at DESC
                LIMIT \(Self.imageHistoryLimit)
              );
        """)
    }

    // MARK: - Read

    func all() -> [Clip] {
        let sql = """
            SELECT id, text, created_at, pinned,
                   kind, image_path, thumbnail, image_width, image_height, image_bytes,
                   pinned_at, is_password
            FROM clips
            ORDER BY pinned DESC,
                     CASE WHEN pinned = 1 THEN pinned_at ELSE created_at END DESC;
        """
        var stmt: OpaquePointer?
        var out: [Clip] = []
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let cText = sqlite3_column_text(stmt, 1)
            let rawText = cText != nil ? String(cString: cText!) : ""
            let created = sqlite3_column_int64(stmt, 2)
            let pinned = sqlite3_column_int(stmt, 3) != 0
            let kindRaw = Int(sqlite3_column_int(stmt, 4))
            let kind = ClipKind(rawValue: kindRaw) ?? .text

            let imagePath: String? = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
            var thumb: Data?
            if sqlite3_column_type(stmt, 6) != SQLITE_NULL,
               let bytes = sqlite3_column_blob(stmt, 6) {
                let n = Int(sqlite3_column_bytes(stmt, 6))
                thumb = Data(bytes: bytes, count: n)
            }
            let w = Int(sqlite3_column_int(stmt, 7))
            let h = Int(sqlite3_column_int(stmt, 8))
            let bytes = sqlite3_column_int64(stmt, 9)

            var pinnedAt: Date?
            if sqlite3_column_type(stmt, 10) != SQLITE_NULL {
                let ms = sqlite3_column_int64(stmt, 10)
                pinnedAt = Date(timeIntervalSince1970: Double(ms) / 1000)
            }
            let isPassword = sqlite3_column_int(stmt, 11) != 0

            // For image rows, hide the synthetic dedup key from callers.
            let displayText = (kind == .image) ? "" : rawText

            out.append(Clip(
                id: id,
                kind: kind,
                text: displayText,
                imagePath: imagePath,
                thumbnail: thumb,
                imageWidth: w,
                imageHeight: h,
                imageBytes: bytes,
                createdAt: Date(timeIntervalSince1970: Double(created) / 1000),
                pinned: pinned,
                pinnedAt: pinnedAt,
                isPassword: isPassword
            ))
        }
        sqlite3_finalize(stmt)
        return out
    }

    /// Reads the full image bytes from disk for the given clip.
    func imageData(for clip: Clip) -> Data? {
        guard let path = clip.imagePath else { return nil }
        let url = imagesDir.appendingPathComponent(path)
        return try? Data(contentsOf: url)
    }

    // MARK: - Mutations

    /// Updates the text of an existing text clip. Returns false if the new
    /// text is empty or collides with another row's text (UNIQUE constraint).
    func updateText(id: Int64, newText: String) -> Bool {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT id FROM clips WHERE text = ? AND id != ?;", -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, newText, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, id)
        let collision = sqlite3_step(stmt) == SQLITE_ROW
        sqlite3_finalize(stmt)
        if collision { return false }

        sqlite3_prepare_v2(db, "UPDATE clips SET text = ? WHERE id = ? AND kind = 0;", -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, newText, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, id)
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)
        return ok
    }

    func togglePassword(id: Int64) {
        let sql = "UPDATE clips SET is_password = 1 - is_password WHERE id = ?;"
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        sqlite3_bind_int64(stmt, 1, id)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
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
        // Look up the image path before deleting so we can clean up the file.
        let path = imagePath(forID: id)

        let sql = "DELETE FROM clips WHERE id = ? AND pinned = 0;"
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        sqlite3_bind_int64(stmt, 1, id)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)

        unlinkImageIfUnreferenced(path: path, excludingID: id)
    }

    func clearUnpinned() {
        // Collect image filenames to remove from disk.
        var paths: [String] = []
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT image_path FROM clips WHERE pinned = 0 AND kind = 1;", -1, &stmt, nil)
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) {
                paths.append(String(cString: c))
            }
        }
        sqlite3_finalize(stmt)

        exec("DELETE FROM clips WHERE pinned = 0;")

        for p in paths {
            unlinkImageIfUnreferenced(path: p, excludingID: nil)
        }
    }

    // MARK: - Groups

    /// Creates a group. Returns the new id, or nil if the name is empty or
    /// already exists (UNIQUE constraint).
    func createGroup(name: String) -> Int64? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO groups (name, created_at) VALUES (?, ?);", -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, trimmed, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, now)
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)
        guard ok else { return nil }
        return sqlite3_last_insert_rowid(db)
    }

    func listGroups() -> [ClipGroup] {
        let sql = """
            SELECT g.id, g.name, g.created_at,
                   (SELECT COUNT(*) FROM group_clips gc WHERE gc.group_id = g.id) AS n
            FROM groups g
            ORDER BY g.created_at DESC;
        """
        var stmt: OpaquePointer?
        var out: [ClipGroup] = []
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let created = sqlite3_column_int64(stmt, 2)
            let count = Int(sqlite3_column_int64(stmt, 3))
            out.append(ClipGroup(
                id: id, name: name,
                createdAt: Date(timeIntervalSince1970: Double(created) / 1000),
                itemCount: count
            ))
        }
        sqlite3_finalize(stmt)
        return out
    }

    func renameGroup(id: Int64, newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }

        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "UPDATE groups SET name = ? WHERE id = ?;", -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, trimmed, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, id)
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)
        return ok
    }

    func deleteGroup(id: Int64) {
        // ON DELETE CASCADE on group_clips removes the membership rows.
        // Affected clips are not deleted; they may now be eligible for trim.
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "DELETE FROM groups WHERE id = ?;", -1, &stmt, nil)
        sqlite3_bind_int64(stmt, 1, id)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    func addClipToGroup(clipID: Int64, groupID: Int64) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let sql = """
            INSERT INTO group_clips (group_id, clip_id, added_at) VALUES (?, ?, ?)
            ON CONFLICT(group_id, clip_id) DO NOTHING;
        """
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        sqlite3_bind_int64(stmt, 1, groupID)
        sqlite3_bind_int64(stmt, 2, clipID)
        sqlite3_bind_int64(stmt, 3, now)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    func removeClipFromGroup(clipID: Int64, groupID: Int64) {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "DELETE FROM group_clips WHERE group_id = ? AND clip_id = ?;", -1, &stmt, nil)
        sqlite3_bind_int64(stmt, 1, groupID)
        sqlite3_bind_int64(stmt, 2, clipID)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    /// Returns clips that belong to the given group, sorted by when they were
    /// added to the group (most recent first).
    func clipsInGroup(_ groupID: Int64) -> [Clip] {
        let sql = """
            SELECT c.id, c.text, c.created_at, c.pinned,
                   c.kind, c.image_path, c.thumbnail, c.image_width, c.image_height, c.image_bytes,
                   c.pinned_at, c.is_password
            FROM clips c
            JOIN group_clips gc ON gc.clip_id = c.id
            WHERE gc.group_id = ?
            ORDER BY gc.added_at DESC;
        """
        var stmt: OpaquePointer?
        var out: [Clip] = []
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        sqlite3_bind_int64(stmt, 1, groupID)
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(readClipRow(stmt))
        }
        sqlite3_finalize(stmt)
        return out
    }

    private func readClipRow(_ stmt: OpaquePointer?) -> Clip {
        let id = sqlite3_column_int64(stmt, 0)
        let cText = sqlite3_column_text(stmt, 1)
        let rawText = cText != nil ? String(cString: cText!) : ""
        let created = sqlite3_column_int64(stmt, 2)
        let pinned = sqlite3_column_int(stmt, 3) != 0
        let kindRaw = Int(sqlite3_column_int(stmt, 4))
        let kind = ClipKind(rawValue: kindRaw) ?? .text

        let imagePath: String? = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
        var thumb: Data?
        if sqlite3_column_type(stmt, 6) != SQLITE_NULL,
           let bytes = sqlite3_column_blob(stmt, 6) {
            let n = Int(sqlite3_column_bytes(stmt, 6))
            thumb = Data(bytes: bytes, count: n)
        }
        let w = Int(sqlite3_column_int(stmt, 7))
        let h = Int(sqlite3_column_int(stmt, 8))
        let bytes = sqlite3_column_int64(stmt, 9)

        var pinnedAt: Date?
        if sqlite3_column_type(stmt, 10) != SQLITE_NULL {
            let ms = sqlite3_column_int64(stmt, 10)
            pinnedAt = Date(timeIntervalSince1970: Double(ms) / 1000)
        }
        let isPassword = sqlite3_column_int(stmt, 11) != 0
        let displayText = (kind == .image) ? "" : rawText

        return Clip(
            id: id, kind: kind, text: displayText,
            imagePath: imagePath, thumbnail: thumb,
            imageWidth: w, imageHeight: h, imageBytes: bytes,
            createdAt: Date(timeIntervalSince1970: Double(created) / 1000),
            pinned: pinned, pinnedAt: pinnedAt, isPassword: isPassword
        )
    }

    enum MoveDirection { case up, down }

    /// Swaps the ordering timestamps of two clips so the user can reorder
    /// them in the visible list. The caller decides which two IDs to swap
    /// (typically the selected clip and its visible neighbor) and which
    /// column to swap (pinned_at for pinned clips, created_at otherwise).
    func swapOrdering(a: Int64, b: Int64, pinned: Bool) {
        let column = pinned ? "pinned_at" : "created_at"
        guard
            let v1 = fetchInt64(column, id: a),
            let v2 = fetchInt64(column, id: b)
        else { return }
        setInt64(column, id: a, value: v2)
        setInt64(column, id: b, value: v1)
    }

    /// Drag-to-reorder: writes a new timestamp value for one clip. Used by
    /// the store after computing a redistribution of timestamps across the
    /// reordered list (so other clips effectively "shift" rather than swap).
    func setOrdering(id: Int64, value: Int64, pinned: Bool) {
        let column = pinned ? "pinned_at" : "created_at"
        setInt64(column, id: id, value: value)
    }

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

    // MARK: - Helpers

    private func imagePath(forID id: Int64) -> String? {
        let sql = "SELECT image_path FROM clips WHERE id = ?;"
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        sqlite3_bind_int64(stmt, 1, id)
        var out: String?
        if sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) {
            out = String(cString: c)
        }
        sqlite3_finalize(stmt)
        return out
    }

    /// Removes the image file iff no other row still references it (the same
    /// hash can be re-inserted on dedup; pinned rows keep it alive).
    private func unlinkImageIfUnreferenced(path: String?, excludingID: Int64?) {
        guard let path else { return }
        let sql: String
        if excludingID != nil {
            sql = "SELECT COUNT(*) FROM clips WHERE image_path = ? AND id != ?;"
        } else {
            sql = "SELECT COUNT(*) FROM clips WHERE image_path = ?;"
        }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
        if let id = excludingID {
            sqlite3_bind_int64(stmt, 2, id)
        }
        var count: Int64 = 0
        if sqlite3_step(stmt) == SQLITE_ROW {
            count = sqlite3_column_int64(stmt, 0)
        }
        sqlite3_finalize(stmt)

        if count == 0 {
            let url = imagesDir.appendingPathComponent(path)
            try? FileManager.default.removeItem(at: url)
        }
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

// MARK: - Image utilities

private func sha256Hex(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}

private func pngEncode(_ data: Data) -> Data? {
    guard let rep = NSBitmapImageRep(data: data) else {
        // Fall back via NSImage for formats NSBitmapImageRep can't decode directly.
        guard let img = NSImage(data: data),
              let tiff = img.tiffRepresentation,
              let r = NSBitmapImageRep(data: tiff)
        else { return nil }
        return r.representation(using: .png, properties: [:])
    }
    return rep.representation(using: .png, properties: [:])
}

private func imageDimensions(_ pngData: Data) -> (Int, Int) {
    guard let rep = NSBitmapImageRep(data: pngData) else { return (0, 0) }
    return (rep.pixelsWide, rep.pixelsHigh)
}

private func makeThumbnail(_ pngData: Data) -> Data? {
    guard let src = NSImage(data: pngData) else { return nil }
    let maxDim = Database.thumbnailMaxDim
    let size = src.size
    guard size.width > 0, size.height > 0 else { return nil }
    let scale = min(1.0, maxDim / max(size.width, size.height))
    let target = NSSize(width: floor(size.width * scale), height: floor(size.height * scale))

    let thumb = NSImage(size: target)
    thumb.lockFocus()
    src.draw(in: NSRect(origin: .zero, size: target),
             from: NSRect(origin: .zero, size: size),
             operation: .copy,
             fraction: 1.0)
    thumb.unlockFocus()

    guard let tiff = thumb.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff)
    else { return nil }
    return rep.representation(using: .png, properties: [.compressionFactor: 0.6])
}
