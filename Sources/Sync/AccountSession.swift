import Foundation

/// Owns the network connections for one account and keeps the local cache in step with the server.
final class AccountSession {
    private(set) var account: Account
    private let client: IMAPClient
    private var idleTask: Task<Void, Never>?
    private let db = MailDatabase.shared
    private var cachedTokens: OAuthTokens?

    /// Messages fetched per batch on first sync / "load older".
    static let batchSize = 150

    init(account: Account) {
        self.account = account
        client = IMAPClient(host: account.servers.imapHost, port: account.servers.imapPort, security: account.servers.imapSecurity)
    }

    func update(account: Account) { self.account = account }

    // MARK: Credentials

    func credentials() async throws -> MailAuth {
        switch account.authKind {
        case .password:
            guard let pw = Keychain.string(for: Keychain.passwordKey(account.id)), !pw.isEmpty else {
                throw MailError.notConfigured("No password saved for \(account.email). Open Settings → Accounts to sign in again.")
            }
            return .password(user: account.username, password: pw)
        case .oauthMicrosoft, .oauthGoogle:
            let provider: OAuthProvider = account.authKind == .oauthMicrosoft ? .microsoft : .google
            var tokens = cachedTokens
            if tokens == nil, let d = Keychain.data(for: Keychain.oauthKey(account.id)) {
                tokens = try? JSONDecoder().decode(OAuthTokens.self, from: d)
            }
            guard var t = tokens else {
                throw MailError.notConfigured("Please sign in to \(account.email) again (Settings → Accounts).")
            }
            if t.expiry < Date() {
                t = try await OAuthFlow.refresh(provider: provider, refreshToken: t.refreshToken)
                if let d = try? JSONEncoder().encode(t) { Keychain.set(d, for: Keychain.oauthKey(account.id)) }
            }
            cachedTokens = t
            return .oauth(user: account.username, accessToken: t.accessToken)
        }
    }

    /// Runs an operation, reconnecting once if the connection dropped.
    private func withClient<T>(_ body: (IMAPClient) async throws -> T) async throws -> T {
        if !client.isConnected { try await client.connect(auth: try await credentials()) }
        do {
            return try await body(client)
        } catch MailError.connectionClosed, MailError.timeout {
            await client.disconnect()
            try await client.connect(auth: try await credentials())
            return try await body(client)
        }
    }

    /// Checks that we can sign in (used when adding an account).
    static func verify(account: Account, auth: MailAuth) async throws {
        let c = IMAPClient(host: account.servers.imapHost, port: account.servers.imapPort, security: account.servers.imapSecurity)
        try await c.connect(auth: auth)
        _ = try await c.listMailboxes()
        await c.disconnect()
        let smtp = SMTPClient(host: account.servers.smtpHost, port: account.servers.smtpPort, security: account.servers.smtpSecurity)
        do {
            try await smtp.verify(auth: auth)
        } catch {
            throw MailError.server("Incoming mail works, but the outgoing server (\(account.servers.smtpHost)) failed: \(error.localizedDescription)")
        }
    }

    // MARK: Folders

    func fetchFolders() async throws -> [Folder] {
        let boxes = try await withClient { try await $0.listMailboxes() }
        var folders = boxes.filter(\.isSelectable).map {
            Folder(accountID: account.id, path: $0.path, name: $0.name, delimiter: $0.delimiter, role: Folder.role(for: $0))
        }
        // Keep only one folder per special role (Gmail can expose duplicates)
        var seen = Set<FolderRole>()
        for i in folders.indices where folders[i].role != .other && folders[i].role != .inbox {
            if seen.contains(folders[i].role) { folders[i].role = .other } else { seen.insert(folders[i].role) }
        }
        return folders.sorted {
            if $0.role.sortOrder != $1.role.sortOrder { return $0.role.sortOrder < $1.role.sortOrder }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    // MARK: Sync

    /// Brings one folder up to date. Returns messages that are new since the last sync.
    @discardableResult
    func sync(folder: String) async throws -> [MessageSummary] {
        let accountID = account.id
        return try await withClient { c in
            let info = try await c.select(folder)
            if let stored = db.uidValidity(account: accountID, folder: folder), stored != info.uidValidity {
                db.clearFolder(account: accountID, folder: folder)
            }
            db.setUIDValidity(info.uidValidity, account: accountID, folder: folder)

            let cached = db.uids(account: accountID, folder: folder)
            guard info.exists > 0 else {
                if !cached.isEmpty { db.delete(account: accountID, folder: folder, uids: cached) }
                return []
            }

            if cached.isEmpty {
                let start = max(1, info.exists - AccountSession.batchSize + 1)
                let items = try await c.fetchSummaries(in: folder, sequence: "\(start):*")
                let summaries = items.map { MessageSummary.make(accountID: accountID, folderPath: folder, summary: $0) }
                db.upsert(summaries)
                return []   // first sync: don't treat as "new"
            }

            var newOnes: [MessageSummary] = []
            let maxUID = cached.last ?? 0
            if info.uidNext == 0 || info.uidNext > maxUID + 1 {
                let items = try await c.fetchSummaries(in: folder, uids: "\(maxUID + 1):*").filter { $0.uid > maxUID }
                newOnes = items.map { MessageSummary.make(accountID: accountID, folderPath: folder, summary: $0) }
                db.upsert(newOnes)
            }

            // Flag changes and deletions for everything we have cached.
            if let minUID = cached.first {
                let server = try await c.fetchFlags(in: folder, uids: "\(minUID):\(maxUID)")
                let gone = cached.filter { server[$0] == nil }
                db.delete(account: accountID, folder: folder, uids: gone)
                db.updateFlags(account: accountID, folder: folder, flags: server.mapValues { MessageFlags(imap: $0) })
            }
            return newOnes
        }
    }

    /// Loads an older batch of messages into the cache. Returns false when nothing is left.
    func loadOlder(folder: String) async throws -> Bool {
        let accountID = account.id
        let cached = db.uids(account: accountID, folder: folder)
        guard let minUID = cached.first else { return false }
        return try await withClient { c in
            let older = try await c.uidsBelow(minUID, in: folder)
            guard !older.isEmpty else { return false }
            let batch = Array(older.suffix(AccountSession.batchSize))
            let items = try await c.fetchSummaries(in: folder, uids: IMAPClient.uidSet(batch))
            db.upsert(items.map { MessageSummary.make(accountID: accountID, folderPath: folder, summary: $0) })
            return true
        }
    }

    func serverSearch(folder: String, text: String) async throws -> [MessageSummary] {
        let accountID = account.id
        return try await withClient { c in
            let uids = try await c.searchUIDs(in: folder, query: text)
            let latest = Array(uids.sorted().suffix(200))
            guard !latest.isEmpty else { return [] }
            let known = Set(db.uids(account: accountID, folder: folder))
            let missing = latest.filter { !known.contains($0) }
            if !missing.isEmpty {
                let items = try await c.fetchSummaries(in: folder, uids: IMAPClient.uidSet(missing))
                db.upsert(items.map { MessageSummary.make(accountID: accountID, folderPath: folder, summary: $0) })
            }
            let wanted = Set(latest)
            return db.messages(account: accountID, folder: folder, limit: 100_000).filter { wanted.contains($0.uid) }
        }
    }

    // MARK: Message content

    func rawMessage(folder: String, uid: UInt32) async throws -> Data {
        if let d = db.body(account: account.id, folder: folder, uid: uid) { return d }
        let data = try await withClient { try await $0.fetchMessage(in: folder, uid: uid) }
        db.saveBody(data, account: account.id, folder: folder, uid: uid)
        return data
    }

    // MARK: Actions

    func setFlag(_ flag: String, on: Bool, folder: String, uids: [UInt32]) async throws {
        try await withClient { try await $0.store(in: folder, uids: uids, add: on, flags: [flag]) }
    }

    func move(folder: String, uids: [UInt32], to destination: String) async throws {
        try await withClient { try await $0.move(in: folder, uids: uids, to: destination) }
        db.delete(account: account.id, folder: folder, uids: uids)
    }

    func deletePermanently(folder: String, uids: [UInt32]) async throws {
        try await withClient { try await $0.deletePermanently(in: folder, uids: uids) }
        db.delete(account: account.id, folder: folder, uids: uids)
    }

    func append(to folder: String, message: Data, flags: [String]) async throws {
        try await withClient { try await $0.append(to: folder, message: message, flags: flags) }
    }

    func send(_ message: OutgoingMessage, sentFolder: String?) async throws {
        let (data, _) = message.build()
        let smtp = SMTPClient(host: account.servers.smtpHost, port: account.servers.smtpPort, security: account.servers.smtpSecurity)
        try await smtp.send(message: data, from: account.email, recipients: message.allRecipients, auth: try await credentials())
        if !account.provider.serverSavesSent, let sentFolder {
            try? await append(to: sentFolder, message: data, flags: ["\\Seen"])
        }
    }

    // MARK: Push (IDLE)

    func startIdle(onChange: @escaping () -> Void) {
        stopIdle()
        let account = self.account
        idleTask = Task.detached(priority: .utility) { [weak self] in
            var delay: UInt64 = 5
            while !Task.isCancelled {
                guard let self else { return }
                let idleClient = IMAPClient(host: account.servers.imapHost, port: account.servers.imapPort, security: account.servers.imapSecurity)
                do {
                    try await idleClient.connect(auth: try await self.credentials())
                    try await idleClient.select("INBOX")
                    delay = 5
                    while !Task.isCancelled {
                        let outcome = try await idleClient.idle(in: "INBOX")
                        if outcome == .changed { onChange() }
                    }
                } catch {
                    // network hiccup, sleep, token expiry… back off and retry
                }
                await idleClient.disconnect()
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delay = min(delay * 2, 300)
            }
        }
    }

    func stopIdle() {
        idleTask?.cancel()
        idleTask = nil
    }

    func shutdown() async {
        stopIdle()
        await client.disconnect()
    }
}
