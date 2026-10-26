import Foundation
import SQLite3
import CryptoKit

/// Every file Tidings writes lives under these three folders — which is what makes a clean uninstall possible.
enum AppPaths {
    static let bundleID = "com.ahmedalbazzaz.tidings"

    static var support: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Tidings", isDirectory: true)
        ensure(url)
        return url
    }

    static var caches: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(bundleID, isDirectory: true)
        ensure(url)
        return url
    }

    static var attachmentsTemp: URL {
        let url = caches.appendingPathComponent("Opened Attachments", isDirectory: true)
        ensure(url)
        return url
    }

    static func ensure(_ url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    /// Everything that may exist outside the app bundle.
    static var allLeftovers: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let lib = home.appendingPathComponent("Library")
        return [
            lib.appendingPathComponent("Application Support/Tidings"),
            lib.appendingPathComponent("Caches/\(bundleID)"),
            lib.appendingPathComponent("Preferences/\(bundleID).plist"),
            lib.appendingPathComponent("Saved Application State/\(bundleID).savedState"),
            lib.appendingPathComponent("HTTPStorages/\(bundleID)"),
            lib.appendingPathComponent("HTTPStorages/\(bundleID).binarycookies"),
            lib.appendingPathComponent("WebKit/\(bundleID)"),
            lib.appendingPathComponent("Containers/\(bundleID)"),
            lib.appendingPathComponent("Application Scripts/\(bundleID)"),
            lib.appendingPathComponent("Cookies/\(bundleID).binarycookies"),
        ]
    }
}

/// Local cache of message summaries and (encrypted) message bodies.
final class MailDatabase {
    static let shared = MailDatabase()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "tidings.db")
    private let key: SymmetricKey

    private init() {
        // The body cache is encrypted with a random key that only lives in the Keychain.
        if let raw = Keychain.data(for: Keychain.cacheKeyName), raw.count == 32 {
            key = SymmetricKey(data: raw)
        } else {
            let k = SymmetricKey(size: .bits256)
            let raw = k.withUnsafeBytes { Data($0) }
            Keychain.set(raw, for: Keychain.cacheKeyName)
            key = k
        }
        let path = AppPaths.support.appendingPathComponent("Mail.sqlite").path
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            db = nil
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        exec("""
        CREATE TABLE IF NOT EXISTS messages(
            account TEXT NOT NULL, folder TEXT NOT NULL, uid INTEGER NOT NULL,
            message_id TEXT, subject TEXT, from_name TEXT, from_email TEXT,
            to_json TEXT, cc_json TEXT, date REAL, flags INTEGER, size INTEGER,
            snippet TEXT, has_att INTEGER, in_reply_to TEXT, refs TEXT, snooze REAL,
            PRIMARY KEY(account, folder, uid))
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_msg_date ON messages(account, folder, date DESC)")
        exec("CREATE INDEX IF NOT EXISTS idx_msg_snooze ON messages(snooze)")
        // 1.2.0: phishing risk score (fails harmlessly when the column already exists)
        exec("ALTER TABLE messages ADD COLUMN risk INTEGER DEFAULT 0")
        exec("""
        CREATE TABLE IF NOT EXISTS bodies(
            account TEXT NOT NULL, folder TEXT NOT NULL, uid INTEGER NOT NULL,
            data BLOB, accessed REAL, PRIMARY KEY(account, folder, uid))
        """)
        exec("CREATE TABLE IF NOT EXISTS folder_state(account TEXT NOT NULL, folder TEXT NOT NULL, uidvalidity INTEGER, PRIMARY KEY(account, folder))")
    }

    // MARK: SQLite plumbing

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        queue.sync { sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK }
    }

    enum Bind { case text(String?), int(Int64), double(Double?), blob(Data?) }

    private func bind(_ stmt: OpaquePointer?, _ values: [Bind]) {
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case .text(let s):
                if let s { sqlite3_bind_text(stmt, idx, s, -1, MailDatabase.transient) } else { sqlite3_bind_null(stmt, idx) }
            case .int(let n): sqlite3_bind_int64(stmt, idx, n)
            case .double(let d):
                if let d { sqlite3_bind_double(stmt, idx, d) } else { sqlite3_bind_null(stmt, idx) }
            case .blob(let d):
                if let d {
                    _ = d.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(d.count), MailDatabase.transient) }
                } else { sqlite3_bind_null(stmt, idx) }
            }
        }
    }

    private func run(_ sql: String, _ values: [Bind] = []) {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            bind(stmt, values)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    private func query<T>(_ sql: String, _ values: [Bind] = [], row: (OpaquePointer?) -> T) -> [T] {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            bind(stmt, values)
            var out: [T] = []
            while sqlite3_step(stmt) == SQLITE_ROW { out.append(row(stmt)) }
            sqlite3_finalize(stmt)
            return out
        }
    }

    private func transaction(_ body: () -> Void) {
        exec("BEGIN")
        body()
        exec("COMMIT")
    }

    private static func text(_ stmt: OpaquePointer?, _ i: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: c)
    }

    private static func blob(_ stmt: OpaquePointer?, _ i: Int32) -> Data? {
        guard let p = sqlite3_column_blob(stmt, i) else { return nil }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
    }

    // MARK: Messages

    private static let columns = "account, folder, uid, message_id, subject, from_name, from_email, to_json, cc_json, date, flags, size, snippet, has_att, in_reply_to, refs, snooze, risk"

    private static func encodeAddresses(_ a: [MailAddress]) -> String {
        (try? String(decoding: JSONEncoder().encode(a), as: UTF8.self)) ?? "[]"
    }

    private static func decodeAddresses(_ s: String) -> [MailAddress] {
        (try? JSONDecoder().decode([MailAddress].self, from: Data(s.utf8))) ?? []
    }

    private static func summary(_ st: OpaquePointer?) -> MessageSummary {
        MessageSummary(
            accountID: UUID(uuidString: text(st, 0)) ?? UUID(),
            folderPath: text(st, 1),
            uid: UInt32(truncatingIfNeeded: sqlite3_column_int64(st, 2)),
            messageID: text(st, 3),
            subject: text(st, 4),
            from: MailAddress(name: text(st, 5), email: text(st, 6)),
            to: decodeAddresses(text(st, 7)),
            cc: decodeAddresses(text(st, 8)),
            date: Date(timeIntervalSince1970: sqlite3_column_double(st, 9)),
            flags: MessageFlags(rawValue: Int(sqlite3_column_int64(st, 10))),
            size: Int(sqlite3_column_int64(st, 11)),
            snippet: text(st, 12),
            hasAttachments: sqlite3_column_int64(st, 13) != 0,
            inReplyTo: { let s = text(st, 14); return s.isEmpty ? nil : s }(),
            references: text(st, 15).split(separator: " ").map(String.init),
            snoozeUntil: sqlite3_column_type(st, 16) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(st, 16)),
            risk: Int(sqlite3_column_int64(st, 17)))
    }

    func upsert(_ items: [MessageSummary]) {
        guard !items.isEmpty else { return }
        transaction {
            for m in items {
                run("""
                INSERT INTO messages(\(MailDatabase.columns)) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,NULL,?)
                ON CONFLICT(account, folder, uid) DO UPDATE SET flags=excluded.flags, snippet=excluded.snippet,
                    subject=excluded.subject, has_att=excluded.has_att, risk=excluded.risk
                """, [
                    .text(m.accountID.uuidString), .text(m.folderPath), .int(Int64(m.uid)), .text(m.messageID),
                    .text(m.subject), .text(m.from.name), .text(m.from.email),
                    .text(MailDatabase.encodeAddresses(m.to)), .text(MailDatabase.encodeAddresses(m.cc)),
                    .double(m.date.timeIntervalSince1970), .int(Int64(m.flags.rawValue)), .int(Int64(m.size)),
                    .text(m.snippet), .int(m.hasAttachments ? 1 : 0), .text(m.inReplyTo), .text(m.references.joined(separator: " ")),
                    .int(Int64(m.risk)),
                ])
            }
        }
    }

    func messages(account: UUID, folder: String, limit: Int = 2000) -> [MessageSummary] {
        query("SELECT \(MailDatabase.columns) FROM messages WHERE account=? AND folder=? AND (snooze IS NULL OR snooze <= ?) ORDER BY date DESC LIMIT ?",
              [.text(account.uuidString), .text(folder), .double(Date().timeIntervalSince1970), .int(Int64(limit))], row: MailDatabase.summary)
    }

    func messages(in boxes: [(UUID, String)], limit: Int = 2000) -> [MessageSummary] {
        var all: [MessageSummary] = []
        for (a, f) in boxes { all += messages(account: a, folder: f, limit: limit) }
        return all.sorted { $0.date > $1.date }.prefix(limit).map { $0 }
    }

    func setRisk(account: UUID, folder: String, uid: UInt32, risk: Int) {
        run("UPDATE messages SET risk=? WHERE account=? AND folder=? AND uid=?",
            [.int(Int64(risk)), .text(account.uuidString), .text(folder), .int(Int64(uid))])
    }

    func snoozed() -> [MessageSummary] {
        query("SELECT \(MailDatabase.columns) FROM messages WHERE snooze IS NOT NULL AND snooze > ? ORDER BY snooze ASC",
              [.double(Date().timeIntervalSince1970)], row: MailDatabase.summary)
    }

    func flagged() -> [MessageSummary] {
        query("SELECT \(MailDatabase.columns) FROM messages WHERE (flags & ?) != 0 ORDER BY date DESC LIMIT 1000",
              [.int(Int64(MessageFlags.flagged.rawValue))], row: MailDatabase.summary)
    }

    func search(_ text: String, accounts: [UUID]? = nil, limit: Int = 300) -> [MessageSummary] {
        let like = "%" + text.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: "_", with: "") + "%"
        return query("""
            SELECT \(MailDatabase.columns) FROM messages
            WHERE subject LIKE ? OR from_name LIKE ? OR from_email LIKE ? OR snippet LIKE ? OR to_json LIKE ?
            ORDER BY date DESC LIMIT ?
            """, [.text(like), .text(like), .text(like), .text(like), .text(like), .int(Int64(limit))], row: MailDatabase.summary)
    }

    /// People you have received mail from, for address autocomplete.
    func contacts(matching prefix: String, limit: Int = 6) -> [MailAddress] {
        let p = prefix.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: "_", with: "")
        guard !p.isEmpty else { return [] }
        return query("""
            SELECT from_name, from_email, COUNT(*) AS n FROM messages
            WHERE from_email LIKE ? OR from_name LIKE ?
            GROUP BY lower(from_email) ORDER BY n DESC LIMIT ?
            """, [.text(p + "%"), .text("%" + p + "%"), .int(Int64(limit))]) {
            MailAddress(name: MailDatabase.text($0, 0), email: MailDatabase.text($0, 1))
        }.filter { MailAddress.isValidEmail($0.email) && !$0.email.lowercased().contains("noreply") && !$0.email.lowercased().contains("no-reply") }
    }

    func uids(account: UUID, folder: String) -> [UInt32] {
        query("SELECT uid FROM messages WHERE account=? AND folder=? ORDER BY uid", [.text(account.uuidString), .text(folder)]) {
            UInt32(truncatingIfNeeded: sqlite3_column_int64($0, 0))
        }
    }

    func setFlags(account: UUID, folder: String, uid: UInt32, flags: MessageFlags) {
        run("UPDATE messages SET flags=? WHERE account=? AND folder=? AND uid=?",
            [.int(Int64(flags.rawValue)), .text(account.uuidString), .text(folder), .int(Int64(uid))])
    }

    func updateFlags(account: UUID, folder: String, flags: [UInt32: MessageFlags]) {
        guard !flags.isEmpty else { return }
        transaction {
            for (uid, f) in flags {
                run("UPDATE messages SET flags=? WHERE account=? AND folder=? AND uid=?",
                    [.int(Int64(f.rawValue)), .text(account.uuidString), .text(folder), .int(Int64(uid))])
            }
        }
    }

    func setSnooze(account: UUID, folder: String, uid: UInt32, until: Date?) {
        run("UPDATE messages SET snooze=? WHERE account=? AND folder=? AND uid=?",
            [.double(until?.timeIntervalSince1970), .text(account.uuidString), .text(folder), .int(Int64(uid))])
    }

    func delete(account: UUID, folder: String, uids: [UInt32]) {
        guard !uids.isEmpty else { return }
        transaction {
            for u in uids {
                run("DELETE FROM messages WHERE account=? AND folder=? AND uid=?", [.text(account.uuidString), .text(folder), .int(Int64(u))])
                run("DELETE FROM bodies WHERE account=? AND folder=? AND uid=?", [.text(account.uuidString), .text(folder), .int(Int64(u))])
            }
        }
    }

    func clearFolder(account: UUID, folder: String) {
        run("DELETE FROM messages WHERE account=? AND folder=?", [.text(account.uuidString), .text(folder)])
        run("DELETE FROM bodies WHERE account=? AND folder=?", [.text(account.uuidString), .text(folder)])
    }

    func deleteAccount(_ account: UUID) {
        run("DELETE FROM messages WHERE account=?", [.text(account.uuidString)])
        run("DELETE FROM bodies WHERE account=?", [.text(account.uuidString)])
        run("DELETE FROM folder_state WHERE account=?", [.text(account.uuidString)])
        exec("VACUUM")
    }

    func unreadCount(account: UUID, folder: String) -> Int {
        query("SELECT COUNT(*) FROM messages WHERE account=? AND folder=? AND (flags & 1)=0 AND (snooze IS NULL OR snooze <= ?)",
              [.text(account.uuidString), .text(folder), .double(Date().timeIntervalSince1970)]) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
    }

    func uidValidity(account: UUID, folder: String) -> UInt32? {
        query("SELECT uidvalidity FROM folder_state WHERE account=? AND folder=?", [.text(account.uuidString), .text(folder)]) {
            UInt32(truncatingIfNeeded: sqlite3_column_int64($0, 0))
        }.first
    }

    func setUIDValidity(_ v: UInt32, account: UUID, folder: String) {
        run("INSERT INTO folder_state(account, folder, uidvalidity) VALUES(?,?,?) ON CONFLICT(account, folder) DO UPDATE SET uidvalidity=excluded.uidvalidity",
            [.text(account.uuidString), .text(folder), .int(Int64(v))])
    }

    // MARK: Bodies (AES-GCM encrypted at rest)

    func body(account: UUID, folder: String, uid: UInt32) -> Data? {
        guard let sealed = query("SELECT data FROM bodies WHERE account=? AND folder=? AND uid=?",
                                 [.text(account.uuidString), .text(folder), .int(Int64(uid))], row: { MailDatabase.blob($0, 0) }).first ?? nil,
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        run("UPDATE bodies SET accessed=? WHERE account=? AND folder=? AND uid=?",
            [.double(Date().timeIntervalSince1970), .text(account.uuidString), .text(folder), .int(Int64(uid))])
        return plain
    }

    func saveBody(_ data: Data, account: UUID, folder: String, uid: UInt32) {
        guard let sealed = try? AES.GCM.seal(data, using: key).combined else { return }
        run("INSERT OR REPLACE INTO bodies(account, folder, uid, data, accessed) VALUES(?,?,?,?,?)",
            [.text(account.uuidString), .text(folder), .int(Int64(uid)), .blob(sealed), .double(Date().timeIntervalSince1970)])
        pruneBodies()
    }

    /// Keeps the body cache small: only the most recently opened messages are kept.
    private func pruneBodies(keep: Int = 1500) {
        run("DELETE FROM bodies WHERE rowid NOT IN (SELECT rowid FROM bodies ORDER BY accessed DESC LIMIT ?)", [.int(Int64(keep))])
    }

    func clearBodies() {
        exec("DELETE FROM bodies")
        exec("VACUUM")
    }

    func close() {
        queue.sync { _ = sqlite3_close(db); db = nil }
    }
}
