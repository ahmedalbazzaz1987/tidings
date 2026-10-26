import Foundation
import SwiftUI
import AppKit
import UserNotifications

enum SidebarItem: Hashable {
    case allInboxes
    case flagged
    case snoozed
    case bills
    case folder(UUID, String)
}

enum ListFilter: String, CaseIterable, Identifiable {
    case all = "All", unread = "Unread", flagged = "Starred", attachments = "Attachments"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .all: return "line.3.horizontal.decrease.circle"
        case .unread: return "envelope.badge"
        case .flagged: return "star"
        case .attachments: return "paperclip"
        }
    }
}

/// App-wide state: accounts, folders, the visible message list and every user action.
@MainActor
final class MailStore: ObservableObject {
    static let shared = MailStore()

    @Published private(set) var accounts: [Account] = []
    @Published private(set) var folders: [UUID: [Folder]] = [:]
    @Published var selection: SidebarItem? = .allInboxes { didSet { selectedIDs = []; reloadList() } }
    @Published private(set) var messages: [MessageSummary] = []
    @Published var selectedIDs: Set<String> = []
    @Published var searchText = "" { didSet { reloadList() } }
    @Published var filter: ListFilter = .all { didSet { reloadList() } }
    @Published private(set) var syncing: Set<UUID> = []
    @Published private(set) var errors: [UUID: String] = [:]
    @Published var toast: String?
    @Published var templates: [MailTemplate] = []
    @Published private(set) var serverResults: [MessageSummary]?
    @Published private(set) var isSearchingServer = false
    @Published var showAddAccount = false

    private var sessions: [UUID: AccountSession] = [:]
    private let db = MailDatabase.shared
    private var pollTimer: Timer?
    private var snoozeTimer: Timer?
    private var knownSnoozed: [String: Date] = [:]

    private init() {}

    // MARK: Startup

    func start() {
        accounts = Preferences.load([Account].self, from: "accounts.json") ?? []
        templates = Preferences.load([MailTemplate].self, from: "templates.json") ?? MailStore.defaultTemplates
        if let cached = Preferences.load([Folder].self, from: "folders.json") {
            folders = Dictionary(grouping: cached, by: \.accountID)
        }
        for a in accounts { sessions[a.id] = AccountSession(account: a) }
        reloadList()
        refreshAll()
        BillRadar.shared.refresh()
        for a in accounts { startPush(a) }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll(quiet: true) }
        }
        snoozeTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkSnoozes() }
        }
        for m in db.snoozed() { if let d = m.snoozeUntil { knownSnoozed[m.id] = d } }
        if Preferences.shared.notificationsEnabled { Notifier.requestAuthorization() }
    }

    func shutdown() {
        for s in sessions.values { Task { await s.shutdown() } }
        try? FileManager.default.removeItem(at: AppPaths.attachmentsTemp)
    }

    static let defaultTemplates = [
        MailTemplate(name: "Thanks", subject: "", body: "Hi,\n\nThank you for your message — I’ll get back to you shortly.\n\nBest regards,"),
        MailTemplate(name: "Meeting request", subject: "Meeting request", body: "Hi,\n\nWould you be available for a short meeting this week? Please let me know a time that suits you.\n\nThanks,"),
    ]

    // MARK: Accounts

    func account(_ id: UUID) -> Account? { accounts.first { $0.id == id } }
    func session(_ id: UUID) -> AccountSession? { sessions[id] }

    func addAccount(_ account: Account) {
        var a = account
        a.colorIndex = accounts.count
        accounts.append(a)
        saveAccounts()
        let s = AccountSession(account: a)
        sessions[a.id] = s
        refresh(accountID: a.id, includeFolders: true)
        startPush(a)
        selection = .allInboxes
    }

    func updateAccount(_ account: Account) {
        guard let i = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        let serversChanged = accounts[i].servers != account.servers || accounts[i].username != account.username
        accounts[i] = account
        saveAccounts()
        if serversChanged {
            Task { await sessions[account.id]?.shutdown() }
            sessions[account.id] = AccountSession(account: account)
            refresh(accountID: account.id, includeFolders: true)
            startPush(account)
        } else {
            sessions[account.id]?.update(account: account)
        }
    }

    func removeAccount(_ id: UUID) {
        if let s = sessions[id] { Task { await s.shutdown() } }
        sessions[id] = nil
        accounts.removeAll { $0.id == id }
        folders[id] = nil
        Keychain.delete(Keychain.passwordKey(id))
        Keychain.delete(Keychain.oauthKey(id))
        db.deleteAccount(id)
        saveAccounts()
        saveFolders()
        if case .folder(let a, _) = selection, a == id { selection = .allInboxes }
        reloadList()
        updateBadge()
    }

    func moveAccounts(from: IndexSet, to: Int) {
        accounts.move(fromOffsets: from, toOffset: to)
        saveAccounts()
    }

    private func saveAccounts() { Preferences.save(accounts, to: "accounts.json") }
    private func saveFolders() { Preferences.save(folders.values.flatMap { $0 }, to: "folders.json") }
    func saveTemplates() { Preferences.save(templates, to: "templates.json") }

    // MARK: Folders helpers

    func folder(_ accountID: UUID, role: FolderRole) -> Folder? {
        folders[accountID]?.first { $0.role == role }
    }

    func inboxPath(_ accountID: UUID) -> String {
        folder(accountID, role: .inbox)?.path ?? "INBOX"
    }

    func folder(for item: SidebarItem?) -> Folder? {
        guard case .folder(let a, let p) = item else { return nil }
        return folders[a]?.first { $0.path == p }
    }

    var selectionTitle: String {
        switch selection {
        case .allInboxes, .none: return "All Inboxes"
        case .flagged: return "Starred"
        case .snoozed: return "Snoozed"
        case .bills: return "Bills"
        case .folder(let a, _):
            let f = folder(for: selection)
            let name = f?.displayName ?? "Folder"
            return accounts.count > 1 ? "\(name) — \(account(a)?.displayName ?? "")" : name
        }
    }

    var totalInboxUnread: Int {
        accounts.reduce(0) { $0 + (folder($1.id, role: .inbox)?.unread ?? 0) }
    }

    // MARK: Sync

    func refreshAll(quiet: Bool = false) {
        for a in accounts { refresh(accountID: a.id, includeFolders: folders[a.id]?.isEmpty ?? true || !quiet) }
    }

    /// Refreshes the folder list (optionally), the inbox and the currently open folder.
    func refresh(accountID: UUID, includeFolders: Bool = false) {
        guard let session = sessions[accountID], !syncing.contains(accountID) else { return }
        syncing.insert(accountID)
        let openFolder: String? = {
            if case .folder(let a, let p) = selection, a == accountID { return p }
            return nil
        }()
        Task {
            do {
                if includeFolders || (folders[accountID]?.isEmpty ?? true) {
                    let list = try await session.fetchFolders()
                    applyFolders(list, for: accountID)
                }
                let inbox = inboxPath(accountID)
                let newOnes = try await session.sync(folder: inbox)
                notifyNew(newOnes, accountID: accountID)
                if let openFolder, openFolder != inbox { try await session.sync(folder: openFolder) }
                errors[accountID] = nil
            } catch {
                errors[accountID] = error.localizedDescription
            }
            syncing.remove(accountID)
            recountUnread(accountID)
            reloadList()
            if syncing.isEmpty { BillRadar.shared.refresh() }
        }
    }

    /// Syncs a single folder when the user opens it.
    func syncFolder(_ accountID: UUID, _ path: String) {
        guard let session = sessions[accountID] else { return }
        Task {
            do {
                try await session.sync(folder: path)
                errors[accountID] = nil
            } catch {
                errors[accountID] = error.localizedDescription
            }
            recountUnread(accountID)
            reloadList()
        }
    }

    @Published private(set) var loadingOlder = false
    /// Folders known to have nothing older on the server (avoids re-asking on every scroll).
    private var exhausted: Set<String> = []

    var canLoadOlder: Bool {
        searchText.isEmpty && selection != .flagged && selection != .snoozed && selection != .bills
    }

    func loadOlder() {
        guard !loadingOlder, canLoadOlder else { return }
        var targets: [(UUID, String)] = []
        if case .folder(let a, let p) = selection { targets = [(a, p)] }
        else { targets = accounts.map { ($0.id, inboxPath($0.id)) } }
        targets = targets.filter { !exhausted.contains("\($0.0)|\($0.1)") }
        guard !targets.isEmpty else { return }
        loadingOlder = true
        Task {
            for (a, p) in targets {
                guard let s = sessions[a] else { continue }
                do {
                    let more = try await s.loadOlder(folder: p)
                    if !more { exhausted.insert("\(a)|\(p)") }
                } catch {
                    toast = error.localizedDescription
                }
            }
            loadingOlder = false
            reloadList()
        }
    }

    private func applyFolders(_ list: [Folder], for accountID: UUID) {
        let old = Dictionary((folders[accountID] ?? []).map { ($0.path, $0.unread) }, uniquingKeysWith: { a, _ in a })
        folders[accountID] = list.map { f in var f = f; f.unread = old[f.path] ?? 0; return f }
        saveFolders()
    }

    private func recountUnread(_ accountID: UUID) {
        guard var list = folders[accountID] else { return }
        for i in list.indices where list[i].role != .sent && list[i].role != .drafts && list[i].role != .trash && list[i].role != .junk {
            list[i].unread = db.unreadCount(account: accountID, folder: list[i].path)
        }
        folders[accountID] = list
        updateBadge()
    }

    private func updateBadge() {
        let n = totalInboxUnread
        NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }

    private func startPush(_ account: Account) {
        sessions[account.id]?.startIdle { [weak self] in
            Task { @MainActor in self?.refresh(accountID: account.id) }
        }
    }

    // MARK: List

    func reloadList() {
        serverResults = nil
        var list: [MessageSummary]
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            list = db.search(q)
            if case .folder(let a, let p) = selection {
                list = list.filter { $0.accountID == a && $0.folderPath == p }
            } else if selection == .allInboxes {
                // search everywhere when looking at All Inboxes
            }
        } else {
            switch selection {
            case .allInboxes, .none:
                list = db.messages(in: accounts.map { ($0.id, inboxPath($0.id)) }, limit: 3000)
            case .flagged:
                list = db.flagged()
            case .snoozed:
                list = db.snoozed()
            case .bills:
                list = BillRadar.shared.bills.map(\.message)
            case .folder(let a, let p):
                list = db.messages(account: a, folder: p)
            }
        }
        let validAccounts = Set(accounts.map(\.id))
        list = list.filter { validAccounts.contains($0.accountID) }
        switch filter {
        case .all: break
        case .unread: list = list.filter(\.isUnread)
        case .flagged: list = list.filter(\.isFlagged)
        case .attachments: list = list.filter(\.hasAttachments)
        }
        messages = list
        selectedIDs = selectedIDs.filter { id in list.contains { $0.id == id } }
    }

    func searchOnServer() {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        isSearchingServer = true
        let targets: [(UUID, String)]
        if case .folder(let a, let p) = selection { targets = [(a, p)] }
        else { targets = accounts.map { ($0.id, inboxPath($0.id)) } }
        Task {
            var found: [MessageSummary] = []
            for (a, p) in targets {
                if let s = sessions[a], let r = try? await s.serverSearch(folder: p, text: q) { found += r }
            }
            isSearchingServer = false
            let local = Set(messages.map(\.id))
            messages += found.filter { !local.contains($0.id) }
            messages.sort { $0.date > $1.date }
            toast = found.isEmpty ? "No more results on the server" : "Found \(found.count) on the server"
        }
    }

    var selectedMessages: [MessageSummary] { messages.filter { selectedIDs.contains($0.id) } }

    // MARK: Reading

    func loadContent(_ m: MessageSummary) async throws -> ParsedMessage {
        guard let s = sessions[m.accountID] else { throw MailError.notConfigured("Account not found.") }
        let raw = try await s.rawMessage(folder: m.folderPath, uid: m.uid)
        return ParsedMessage(data: raw)
    }

    func rawSource(_ m: MessageSummary) async -> String {
        guard let s = sessions[m.accountID], let raw = try? await s.rawMessage(folder: m.folderPath, uid: m.uid) else { return "" }
        return String(decoding: raw, as: UTF8.self)
    }

    // MARK: Actions

    private func group(_ list: [MessageSummary]) -> [(UUID, String, [UInt32])] {
        var out: [String: (UUID, String, [UInt32])] = [:]
        for m in list {
            let k = "\(m.accountID)|\(m.folderPath)"
            out[k, default: (m.accountID, m.folderPath, [])].2.append(m.uid)
        }
        return Array(out.values)
    }

    private func updateLocal(_ list: [MessageSummary], _ change: (inout MessageFlags) -> Void) {
        for m in list {
            var f = m.flags
            change(&f)
            db.setFlags(account: m.accountID, folder: m.folderPath, uid: m.uid, flags: f)
            if let i = messages.firstIndex(where: { $0.id == m.id }) { messages[i].flags = f }
        }
    }

    /// Stores the reader's full phishing analysis so the list badge matches it.
    func updateRisk(_ m: MessageSummary, risk: Int) {
        guard let i = messages.firstIndex(where: { $0.id == m.id }), messages[i].risk != risk else { return }
        messages[i].risk = risk
        db.setRisk(account: m.accountID, folder: m.folderPath, uid: m.uid, risk: risk)
    }

    func setRead(_ list: [MessageSummary], read: Bool) {
        let targets = list.filter { $0.isUnread == read }
        guard !targets.isEmpty else { return }
        updateLocal(targets) { if read { $0.insert(.seen) } else { $0.remove(.seen) } }
        for (a, p, uids) in group(targets) {
            Task {
                do { try await sessions[a]?.setFlag("\\Seen", on: read, folder: p, uids: uids) }
                catch { toast = error.localizedDescription }
                recountUnread(a)
            }
        }
        for a in Set(targets.map(\.accountID)) { recountUnread(a) }
    }

    func toggleRead(_ list: [MessageSummary]) {
        let anyUnread = list.contains(where: \.isUnread)
        setRead(list, read: anyUnread)
    }

    func toggleFlag(_ list: [MessageSummary]) {
        let flag = !list.allSatisfy(\.isFlagged)
        updateLocal(list) { if flag { $0.insert(.flagged) } else { $0.remove(.flagged) } }
        for (a, p, uids) in group(list) {
            Task {
                do { try await sessions[a]?.setFlag("\\Flagged", on: flag, folder: p, uids: uids) }
                catch { toast = error.localizedDescription }
            }
        }
        if selection == .flagged || filter == .flagged { reloadList() }
    }

    private func removeFromList(_ list: [MessageSummary]) {
        let ids = Set(list.map(\.id))
        // choose the next message to select, like Mail does
        if let last = messages.lastIndex(where: { ids.contains($0.id) }) {
            let next = messages[(last + 1)...].first { !ids.contains($0.id) } ?? messages[..<last].last { !ids.contains($0.id) }
            selectedIDs = next.map { [$0.id] } ?? []
        }
        messages.removeAll { ids.contains($0.id) }
    }

    func archive(_ list: [MessageSummary]) {
        var skipped = false
        let movable = list.filter { m in
            let dest = folder(m.accountID, role: .archive) ?? folder(m.accountID, role: .all)
            if dest == nil || dest?.path == m.folderPath { skipped = true; return false }
            return true
        }
        if skipped && movable.isEmpty { toast = "This account has no Archive folder."; return }
        removeFromList(movable)
        for (a, p, uids) in group(movable) {
            guard let dest = folder(a, role: .archive) ?? folder(a, role: .all) else { continue }
            Task {
                do { try await sessions[a]?.move(folder: p, uids: uids, to: dest.path) }
                catch { toast = error.localizedDescription; reloadList() }
                recountUnread(a)
            }
        }
        if !movable.isEmpty { toast = movable.count == 1 ? "Archived" : "Archived \(movable.count) messages" }
    }

    func delete(_ list: [MessageSummary]) {
        removeFromList(list)
        for (a, p, uids) in group(list) {
            let trash = folder(a, role: .trash)
            Task {
                do {
                    if let trash, trash.path != p {
                        try await sessions[a]?.move(folder: p, uids: uids, to: trash.path)
                    } else {
                        try await sessions[a]?.deletePermanently(folder: p, uids: uids)
                    }
                } catch { toast = error.localizedDescription; reloadList() }
                recountUnread(a)
            }
        }
    }

    func markJunk(_ list: [MessageSummary]) {
        move(list, toRole: .junk, label: "Moved to Junk")
    }

    func move(_ list: [MessageSummary], toRole role: FolderRole, label: String) {
        let movable = list.filter { folder($0.accountID, role: role) != nil }
        guard !movable.isEmpty else { toast = "No \(role.rawValue) folder on this account."; return }
        removeFromList(movable)
        for (a, p, uids) in group(movable) {
            guard let dest = folder(a, role: role), dest.path != p else { continue }
            Task {
                do { try await sessions[a]?.move(folder: p, uids: uids, to: dest.path) }
                catch { toast = error.localizedDescription; reloadList() }
                recountUnread(a)
            }
        }
        toast = label
    }

    func move(_ list: [MessageSummary], to destination: Folder) {
        let movable = list.filter { $0.accountID == destination.accountID && $0.folderPath != destination.path }
        guard !movable.isEmpty else { return }
        removeFromList(movable)
        for (a, p, uids) in group(movable) {
            Task {
                do { try await sessions[a]?.move(folder: p, uids: uids, to: destination.path) }
                catch { toast = error.localizedDescription; reloadList() }
                recountUnread(a)
            }
        }
        toast = "Moved to \(destination.displayName)"
    }

    // MARK: Snooze

    func snooze(_ list: [MessageSummary], until date: Date) {
        for m in list {
            db.setSnooze(account: m.accountID, folder: m.folderPath, uid: m.uid, until: date)
            knownSnoozed[m.id] = date
        }
        removeFromList(list)
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        toast = "Snoozed until \(f.string(from: date))"
        for a in Set(list.map(\.accountID)) { recountUnread(a) }
    }

    func unsnooze(_ list: [MessageSummary]) {
        for m in list {
            db.setSnooze(account: m.accountID, folder: m.folderPath, uid: m.uid, until: nil)
            knownSnoozed[m.id] = nil
        }
        reloadList()
    }

    private func checkSnoozes() {
        let now = Date()
        let due = knownSnoozed.filter { $0.value <= now }
        guard !due.isEmpty else { return }
        for id in due.keys { knownSnoozed[id] = nil }
        reloadList()
        for a in accounts { recountUnread(a.id) }
        let back = messages.filter { due.keys.contains($0.id) }
        for m in back {
            Notifier.post(title: "Reminder: \(m.from.displayName)", body: m.subject.isEmpty ? "(No subject)" : m.subject, id: m.id)
        }
    }

    // MARK: Sending

    func send(_ message: OutgoingMessage, accountID: UUID, replyingTo original: MessageSummary?) async throws {
        guard let s = sessions[accountID] else { throw MailError.notConfigured("Account not found.") }
        try await s.send(message, sentFolder: folder(accountID, role: .sent)?.path)
        if let original {
            var f = original.flags
            f.insert(.answered)
            db.setFlags(account: original.accountID, folder: original.folderPath, uid: original.uid, flags: f)
            try? await sessions[original.accountID]?.setFlag("\\Answered", on: true, folder: original.folderPath, uids: [original.uid])
        }
        toast = "Message sent"
        if case .folder(let a, let p) = selection, a == accountID, p == folder(accountID, role: .sent)?.path {
            syncFolder(a, p)
        }
    }

    func saveDraft(_ message: OutgoingMessage, accountID: UUID) async throws {
        guard let s = sessions[accountID], let drafts = folder(accountID, role: .drafts) else {
            throw MailError.notConfigured("This account has no Drafts folder.")
        }
        let (data, _) = message.build()
        try await s.append(to: drafts.path, message: data, flags: ["\\Draft", "\\Seen"])
        toast = "Draft saved"
    }

    // MARK: Notifications

    private func notifyNew(_ list: [MessageSummary], accountID: UUID) {
        guard Preferences.shared.notificationsEnabled, account(accountID)?.notificationsEnabled ?? true else { return }
        let unread = list.filter(\.isUnread)
        guard !unread.isEmpty else { return }
        if unread.count > 3 {
            Notifier.post(title: account(accountID)?.email ?? "Tidings", body: "\(unread.count) new messages", id: UUID().uuidString)
        } else {
            for m in unread {
                Notifier.post(title: m.from.displayName, subtitle: m.subject, body: m.snippet, id: m.id)
            }
        }
    }
}

enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func post(title: String, subtitle: String = "", body: String, id: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.subtitle = subtitle
        c.body = String(body.prefix(180))
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }
}
