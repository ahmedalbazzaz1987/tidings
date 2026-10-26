import Foundation

/// How we prove who we are to a mail server.
enum MailAuth {
    case password(user: String, password: String)
    case oauth(user: String, accessToken: String)

    var user: String {
        switch self {
        case .password(let u, _), .oauth(let u, _): return u
        }
    }

    /// SASL XOAUTH2 initial response.
    static func xoauth2(user: String, token: String) -> String {
        let s = "user=\(user)\u{01}auth=Bearer \(token)\u{01}\u{01}"
        return Data(s.utf8).base64EncodedString()
    }
}

struct IMAPMailbox {
    let path: String          // as the server names it (modified UTF-7)
    let name: String          // decoded display path
    let delimiter: String?
    let flags: [String]

    var isSelectable: Bool { !flags.contains { $0.caseInsensitiveCompare("\\Noselect") == .orderedSame || $0.caseInsensitiveCompare("\\NonExistent") == .orderedSame } }
    func has(_ flag: String) -> Bool { flags.contains { $0.caseInsensitiveCompare(flag) == .orderedSame } }
}

struct IMAPSelectInfo {
    var exists = 0
    var uidValidity: UInt32 = 0
    var uidNext: UInt32 = 0
}

struct IMAPSummary {
    let uid: UInt32
    let flags: [String]
    let internalDate: Date?
    let size: Int
    let header: Data
    let textPrefix: Data
}

/// Serializes access so that only one command is on the wire at a time.
actor AsyncLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !locked { locked = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
    }
}

/// A minimal but complete IMAP4rev1 client (RFC 3501) with MOVE, UIDPLUS, IDLE and XOAUTH2.
final class IMAPClient {
    let host: String
    let port: Int
    let security: TransportSecurity

    private var socket: MailSocket?
    private var tagCounter = 0
    private let lock = AsyncLock()
    private(set) var capabilities: Set<String> = []
    private(set) var selectedPath: String?
    private(set) var isConnected = false

    init(host: String, port: Int, security: TransportSecurity) {
        self.host = host
        self.port = port
        self.security = security
    }

    // MARK: Connection

    func connect(auth: MailAuth) async throws {
        await lock.acquire()
        if isConnected, socket != nil { await lock.release(); return }
        do {
            try await connectUnlocked(auth: auth)
            await lock.release()
        } catch {
            await lock.release()
            socket?.close(); socket = nil; isConnected = false
            throw error
        }
    }

    private func connectUnlocked(auth: MailAuth) async throws {
        let sock = MailSocket(host: host, port: port)
        sock.readTimeout = 45
        sock.open(security: security)
        socket = sock
        selectedPath = nil

        let greeting = try await readResponse()
        if greeting.status == "BYE" { throw MailError.server(greeting.statusText) }

        if security == .startTLS {
            _ = try await run("STARTTLS")
            sock.upgradeToTLS()
        }
        try await refreshCapabilities()

        switch auth {
        case .oauth(let user, let token):
            let ir = MailAuth.xoauth2(user: user, token: token)
            do {
                _ = try await run("AUTHENTICATE XOAUTH2 \(ir)", onContinuation: { _ in Data("\r\n".utf8) })
            } catch {
                throw MailError.authenticationFailed("The account token was rejected. Try signing in again.")
            }
        case .password(let user, let password):
            if capabilities.contains("LOGINDISABLED") {
                throw MailError.authenticationFailed("The server does not allow password sign-in on this connection.")
            }
            do {
                _ = try await runParts([.text("LOGIN "), .string(user), .text(" "), .string(password)])
            } catch MailError.server(let msg) {
                throw MailError.authenticationFailed(msg.isEmpty ? "Check the email address and password." : msg)
            }
        }
        try await refreshCapabilities()
        isConnected = true
        sock.readTimeout = 90
    }

    func disconnect() async {
        if isConnected {
            await lock.acquire()
            _ = try? await run("LOGOUT")
            await lock.release()
        }
        socket?.close()
        socket = nil
        isConnected = false
        selectedPath = nil
    }

    private func refreshCapabilities() async throws {
        let r = try await run("CAPABILITY")
        var caps = Set<String>()
        for u in r.untagged {
            let v = u.values()
            if v.first?.text?.uppercased() == "CAPABILITY" {
                for item in v.dropFirst() { if let t = item.text { caps.insert(t.uppercased()) } }
            }
        }
        capabilities = caps
    }

    // MARK: Low level

    enum Part {
        case text(String)
        case string(String)   // quoted if possible, otherwise sent as a literal
        case literal(Data)
    }

    private func nextTag() -> String {
        tagCounter += 1
        return "T\(tagCounter)"
    }

    private func readResponse() async throws -> IMAPResponse {
        guard let socket else { throw MailError.connectionClosed }
        var raw = try await socket.readLine()
        while let n = IMAPClient.trailingLiteralSize(raw) {
            raw.append(try await socket.readExactly(n))
            raw.append(try await socket.readLine())
        }
        let first = raw.first
        if first == UInt8(ascii: "*") { return IMAPResponse(kind: .untagged, raw: raw) }
        if first == UInt8(ascii: "+") { return IMAPResponse(kind: .continuation, raw: raw) }
        let tag = String(decoding: raw.prefix { $0 != 0x20 }, as: UTF8.self)
        return IMAPResponse(kind: .tagged(tag), raw: raw)
    }

    /// If a line ends with "{n}\r\n" returns n.
    static func trailingLiteralSize(_ line: Data) -> Int? {
        let bytes = [UInt8](line.suffix(24))
        var end = bytes.count
        while end > 0, bytes[end - 1] == 0x0A || bytes[end - 1] == 0x0D { end -= 1 }
        guard end > 0, bytes[end - 1] == UInt8(ascii: "}") else { return nil }
        var j = end - 2
        var digits = [UInt8]()
        while j >= 0 {
            let b = bytes[j]
            if b >= 0x30 && b <= 0x39 { digits.insert(b, at: 0); j -= 1; continue }
            if b == UInt8(ascii: "+") && digits.isEmpty { j -= 1; continue }
            break
        }
        guard j >= 0, bytes[j] == UInt8(ascii: "{"), !digits.isEmpty else { return nil }
        return Int(String(decoding: digits, as: UTF8.self))
    }

    struct Result {
        var untagged: [IMAPResponse]
        var tagged: IMAPResponse
    }

    /// Runs a simple command. Caller must hold the lock.
    private func run(_ command: String, onContinuation: ((IMAPResponse) -> Data?)? = nil) async throws -> Result {
        try await runParts([.text(command)], onContinuation: onContinuation)
    }

    private func runParts(_ parts: [Part], onContinuation: ((IMAPResponse) -> Data?)? = nil) async throws -> Result {
        guard let socket else { throw MailError.connectionClosed }
        let tag = nextTag()
        var untagged: [IMAPResponse] = []

        // Build segments split at literals.
        var segments: [(String, Data?)] = []
        var current = tag + " "
        for p in parts {
            switch p {
            case .text(let t): current += t
            case .string(let s):
                if let q = IMAPQuote.quoted(s) { current += q } else {
                    let d = Data(s.utf8)
                    segments.append((current + "{\(d.count)}", d))
                    current = ""
                }
            case .literal(let d):
                segments.append((current + "{\(d.count)}", d))
                current = ""
            }
        }

        for (text, literal) in segments {
            try await socket.write(text + "\r\n")
            // wait for continuation
            while true {
                let r = try await readResponse()
                switch r.kind {
                case .continuation:
                    break
                case .untagged:
                    untagged.append(r); continue
                case .tagged:
                    throw MailError.server(r.statusText)
                }
                break
            }
            if let literal { try await socket.write(literal) }
        }
        try await socket.write(current + "\r\n")

        while true {
            let r = try await readResponse()
            switch r.kind {
            case .untagged:
                if r.status == "BYE" { isConnected = false }
                untagged.append(r)
            case .continuation:
                let reply = onContinuation?(r) ?? Data("\r\n".utf8)
                try await socket.write(reply)
            case .tagged(let t):
                guard t == tag else { continue }
                let st = r.status ?? ""
                if st == "OK" { return Result(untagged: untagged, tagged: r) }
                throw MailError.server(r.statusText.isEmpty ? "The server refused the request (\(st))." : r.statusText)
            }
        }
    }

    /// Locked wrapper for public API.
    private func locked<T>(_ body: () async throws -> T) async throws -> T {
        await lock.acquire()
        do {
            let v = try await body()
            await lock.release()
            return v
        } catch {
            await lock.release()
            if case MailError.connectionClosed = error { isConnected = false }
            if case MailError.timeout = error { isConnected = false; socket?.close(); socket = nil }
            throw error
        }
    }

    // MARK: Mailboxes

    func listMailboxes() async throws -> [IMAPMailbox] {
        try await locked {
            let r = try await run("LIST \"\" \"*\"")
            var out: [IMAPMailbox] = []
            for u in r.untagged {
                let v = u.values()
                guard v.count >= 4, v[0].text?.uppercased() == "LIST" else { continue }
                let flags = v[1].list?.compactMap(\.text) ?? []
                let delim: String? = { if case .nilValue = v[2] { return nil }; return v[2].text }()
                guard let path = v[3].text else { continue }
                out.append(IMAPMailbox(path: path, name: ModifiedUTF7.decode(path), delimiter: delim, flags: flags))
            }
            return out
        }
    }

    @discardableResult
    func select(_ path: String, readOnly: Bool = false) async throws -> IMAPSelectInfo {
        try await locked { try await selectUnlocked(path, readOnly: readOnly) }
    }

    private func selectUnlocked(_ path: String, readOnly: Bool = false) async throws -> IMAPSelectInfo {
        let r = try await run((readOnly ? "EXAMINE " : "SELECT ") + IMAPQuote.mailbox(path))
        var info = IMAPSelectInfo()
        for u in r.untagged {
            let v = u.values()
            if v.count >= 2, v[1].text?.uppercased() == "EXISTS", let n = v[0].int { info.exists = n }
            if let code = u.responseCode {
                let parts = code.split(separator: " ")
                if parts.count >= 2 {
                    switch parts[0].uppercased() {
                    case "UIDVALIDITY": info.uidValidity = UInt32(parts[1]) ?? 0
                    case "UIDNEXT": info.uidNext = UInt32(parts[1]) ?? 0
                    default: break
                    }
                }
            }
        }
        selectedPath = path
        return info
    }

    private func ensureSelected(_ path: String) async throws {
        if selectedPath != path { _ = try await selectUnlocked(path) }
    }

    // MARK: Fetching

    static let summaryItems = "(UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[HEADER] BODY.PEEK[TEXT]<0.3072>)"

    /// Fetches summaries by sequence-number range, e.g. "120:*".
    func fetchSummaries(in path: String, sequence: String) async throws -> [IMAPSummary] {
        try await locked {
            try await ensureSelected(path)
            let r = try await run("FETCH \(sequence) \(IMAPClient.summaryItems)")
            return r.untagged.compactMap(IMAPClient.summary(from:))
        }
    }

    /// Fetches summaries by UID set, e.g. "4501:*" or "5,9,12".
    func fetchSummaries(in path: String, uids: String) async throws -> [IMAPSummary] {
        try await locked {
            try await ensureSelected(path)
            let r = try await run("UID FETCH \(uids) \(IMAPClient.summaryItems)")
            return r.untagged.compactMap(IMAPClient.summary(from:))
        }
    }

    private static func summary(from r: IMAPResponse) -> IMAPSummary? {
        guard let items = r.fetchItems()?.items, let uidText = items["UID"]?.text, let uid = UInt32(uidText) else { return nil }
        let flags = items["FLAGS"]?.list?.compactMap(\.text) ?? []
        let date = items["INTERNALDATE"]?.text.flatMap(parseInternalDate)
        let size = items["RFC822.SIZE"]?.int ?? 0
        let header = items.section("BODY[HEADER]") ?? Data()
        let text = items.section("BODY[TEXT]") ?? Data()
        return IMAPSummary(uid: uid, flags: flags, internalDate: date, size: size, header: header, textPrefix: text)
    }

    /// Returns UID → flags for a UID range. Used to detect flag changes and deletions.
    func fetchFlags(in path: String, uids: String) async throws -> [UInt32: [String]] {
        try await locked {
            try await ensureSelected(path)
            let r = try await run("UID FETCH \(uids) (UID FLAGS)")
            var out: [UInt32: [String]] = [:]
            for u in r.untagged {
                guard let items = u.fetchItems()?.items, let uid = items["UID"]?.text.flatMap({ UInt32($0) }) else { continue }
                out[uid] = items["FLAGS"]?.list?.compactMap(\.text) ?? []
            }
            return out
        }
    }

    /// Downloads the full raw message without marking it as read.
    func fetchMessage(in path: String, uid: UInt32) async throws -> Data {
        try await locked {
            try await ensureSelected(path)
            let r = try await run("UID FETCH \(uid) (UID BODY.PEEK[])")
            for u in r.untagged {
                guard let items = u.fetchItems()?.items else { continue }
                if items["UID"]?.text == String(uid), let d = items.section("BODY[]") { return d }
            }
            for u in r.untagged { if let items = u.fetchItems()?.items, let d = items.section("BODY[]") { return d } }
            throw MailError.server("The message is no longer on the server.")
        }
    }

    func searchUIDs(in path: String, query: String) async throws -> [UInt32] {
        try await locked {
            try await ensureSelected(path)
            let isASCII = query.unicodeScalars.allSatisfy { $0.value < 0x7F }
            var parts: [Part] = [.text("UID SEARCH ")]
            if !isASCII { parts.append(.text("CHARSET UTF-8 ")) }
            parts.append(.text("TEXT "))
            parts.append(.string(query))
            let r = try await runParts(parts)
            var out: [UInt32] = []
            for u in r.untagged {
                let v = u.values()
                guard v.first?.text?.uppercased() == "SEARCH" else { continue }
                out.append(contentsOf: v.dropFirst().compactMap { $0.text.flatMap { UInt32($0) } })
            }
            return out
        }
    }

    /// Returns all UIDs strictly below a bound (for "load older").
    func uidsBelow(_ uid: UInt32, in path: String) async throws -> [UInt32] {
        guard uid > 1 else { return [] }
        return try await locked {
            try await ensureSelected(path)
            let r = try await run("UID SEARCH UID 1:\(uid - 1)")
            var out: [UInt32] = []
            for u in r.untagged {
                let v = u.values()
                guard v.first?.text?.uppercased() == "SEARCH" else { continue }
                out.append(contentsOf: v.dropFirst().compactMap { $0.text.flatMap { UInt32($0) } })
            }
            return out.filter { $0 < uid }.sorted()
        }
    }

    // MARK: Changing messages

    func store(in path: String, uids: [UInt32], add: Bool, flags: [String]) async throws {
        guard !uids.isEmpty else { return }
        try await locked {
            try await ensureSelected(path)
            _ = try await run("UID STORE \(IMAPClient.uidSet(uids)) \(add ? "+" : "-")FLAGS.SILENT (\(flags.joined(separator: " ")))")
        }
    }

    func move(in path: String, uids: [UInt32], to destination: String) async throws {
        guard !uids.isEmpty else { return }
        try await locked {
            try await ensureSelected(path)
            let set = IMAPClient.uidSet(uids)
            if capabilities.contains("MOVE") {
                _ = try await run("UID MOVE \(set) \(IMAPQuote.mailbox(destination))")
            } else {
                _ = try await run("UID COPY \(set) \(IMAPQuote.mailbox(destination))")
                _ = try await run("UID STORE \(set) +FLAGS.SILENT (\\Deleted)")
                if capabilities.contains("UIDPLUS") {
                    _ = try await run("UID EXPUNGE \(set)")
                } else {
                    _ = try await run("EXPUNGE")
                }
            }
        }
    }

    /// Permanently deletes messages (used inside Trash).
    func deletePermanently(in path: String, uids: [UInt32]) async throws {
        guard !uids.isEmpty else { return }
        try await locked {
            try await ensureSelected(path)
            let set = IMAPClient.uidSet(uids)
            _ = try await run("UID STORE \(set) +FLAGS.SILENT (\\Deleted)")
            if capabilities.contains("UIDPLUS") {
                _ = try await run("UID EXPUNGE \(set)")
            } else {
                _ = try await run("EXPUNGE")
            }
        }
    }

    func append(to path: String, message: Data, flags: [String]) async throws {
        try await locked {
            _ = try await runParts([.text("APPEND \(IMAPQuote.mailbox(path)) (\(flags.joined(separator: " "))) "), .literal(message)])
        }
    }

    func noop() async throws {
        try await locked { _ = try await run("NOOP") }
    }

    // MARK: IDLE

    enum IdleOutcome { case changed, timedOut }

    /// Waits for mailbox changes using IDLE (RFC 2177). Returns when something changed
    /// or after `maxDuration` so the caller can re-issue IDLE (servers drop idle
    /// connections after ~30 minutes).
    func idle(in path: String, maxDuration: TimeInterval = 20 * 60) async throws -> IdleOutcome {
        try await locked {
            try await ensureSelected(path)
            guard capabilities.contains("IDLE") else {
                try await Task.sleep(nanoseconds: 120 * 1_000_000_000)
                return .timedOut
            }
            guard let socket else { throw MailError.connectionClosed }
            let tag = nextTag()
            try await socket.write("\(tag) IDLE\r\n")
            let first = try await readResponse()
            guard case .continuation = first.kind else { throw MailError.protocolError(first.line) }

            let doneSent = DoneFlag()
            let timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(maxDuration * 1_000_000_000))
                if doneSent.set() { try? await socket.write("DONE\r\n") }
            }
            defer { timer.cancel() }
            socket.readTimeout = maxDuration + 120

            var outcome = IdleOutcome.timedOut
            while true {
                let r = try await readResponse()
                switch r.kind {
                case .untagged:
                    let v = r.values()
                    if v.count >= 2, let word = v[1].text?.uppercased(), ["EXISTS", "EXPUNGE", "FETCH", "RECENT"].contains(word) {
                        outcome = .changed
                        if doneSent.set() { try await socket.write("DONE\r\n") }
                    }
                    if r.status == "BYE" { throw MailError.connectionClosed }
                case .tagged(let t) where t == tag:
                    socket.readTimeout = 90
                    return outcome
                default:
                    continue
                }
            }
        }
    }

    // MARK: Utilities

    static func uidSet(_ uids: [UInt32]) -> String {
        let sorted = Array(Set(uids)).sorted()
        var parts: [String] = []
        var i = 0
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count, sorted[j + 1] == sorted[j] + 1 { j += 1 }
            parts.append(i == j ? "\(sorted[i])" : "\(sorted[i]):\(sorted[j])")
            i = j + 1
        }
        return parts.joined(separator: ",")
    }

    private static let internalDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        return f
    }()

    static func parseInternalDate(_ s: String) -> Date? {
        internalDateFormatter.date(from: s.trimmingCharacters(in: .whitespaces))
    }
}

/// Thread-safe one-shot flag.
final class DoneFlag {
    private var done = false
    private let lock = NSLock()
    /// Returns true the first time only.
    func set() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
