import Foundation
import SwiftUI

// MARK: - Providers

enum MailProvider: String, Codable, CaseIterable, Identifiable {
    case gmail, icloud, outlook, yahoo, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .gmail: return "Gmail"
        case .icloud: return "iCloud Mail"
        case .outlook: return "Outlook / Hotmail"
        case .yahoo: return "Yahoo Mail"
        case .custom: return "Other (IMAP)"
        }
    }

    var subtitle: String {
        switch self {
        case .gmail: return "Google account — app password or Google sign-in"
        case .icloud: return "@icloud.com, @me.com, @mac.com"
        case .outlook: return "@outlook.com, @hotmail.com, @live.com, Microsoft 365"
        case .yahoo: return "@yahoo.com and Yahoo domains"
        case .custom: return "Your own domain, hosting or company mail"
        }
    }

    var symbol: String {
        switch self {
        case .gmail: return "envelope.fill"
        case .icloud: return "icloud.fill"
        case .outlook: return "tray.full.fill"
        case .yahoo: return "at"
        case .custom: return "server.rack"
        }
    }

    var tint: Color {
        switch self {
        case .gmail: return Color(red: 0.86, green: 0.27, blue: 0.22)
        case .icloud: return Color(red: 0.20, green: 0.55, blue: 0.98)
        case .outlook: return Color(red: 0.0, green: 0.47, blue: 0.83)
        case .yahoo: return Color(red: 0.42, green: 0.18, blue: 0.78)
        case .custom: return Color(red: 0.25, green: 0.62, blue: 0.55)
        }
    }

    /// Default server settings.
    func defaults(for email: String) -> ServerSettings {
        switch self {
        case .gmail:
            return ServerSettings(imapHost: "imap.gmail.com", imapPort: 993, imapSecurity: .tls,
                                  smtpHost: "smtp.gmail.com", smtpPort: 465, smtpSecurity: .tls)
        case .icloud:
            return ServerSettings(imapHost: "imap.mail.me.com", imapPort: 993, imapSecurity: .tls,
                                  smtpHost: "smtp.mail.me.com", smtpPort: 587, smtpSecurity: .startTLS)
        case .outlook:
            return ServerSettings(imapHost: "outlook.office365.com", imapPort: 993, imapSecurity: .tls,
                                  smtpHost: "smtp-mail.outlook.com", smtpPort: 587, smtpSecurity: .startTLS)
        case .yahoo:
            return ServerSettings(imapHost: "imap.mail.yahoo.com", imapPort: 993, imapSecurity: .tls,
                                  smtpHost: "smtp.mail.yahoo.com", smtpPort: 465, smtpSecurity: .tls)
        case .custom:
            let domain = email.split(separator: "@").last.map(String.init) ?? "example.com"
            return ServerSettings(imapHost: "mail.\(domain)", imapPort: 993, imapSecurity: .tls,
                                  smtpHost: "mail.\(domain)", smtpPort: 465, smtpSecurity: .tls)
        }
    }

    /// Whether the SMTP server stores a copy in Sent by itself.
    var serverSavesSent: Bool { self == .gmail || self == .outlook }

    var appPasswordHelp: String {
        switch self {
        case .gmail: return "Use a Google App Password (Google Account → Security → 2-Step Verification → App passwords). Your normal password will not work."
        case .icloud: return "Use an app-specific password from account.apple.com → Sign-In and Security → App-Specific Passwords."
        case .yahoo: return "Use an app password from Yahoo Account Security → Generate app password."
        case .outlook: return "Microsoft requires secure sign-in for Outlook.com — use “Sign in with Microsoft”."
        case .custom: return "Use the mailbox password from your hosting control panel (cPanel, Plesk, etc.)."
        }
    }

    static func guess(for email: String) -> MailProvider {
        let domain = email.split(separator: "@").last.map { $0.lowercased() } ?? ""
        if ["gmail.com", "googlemail.com"].contains(domain) { return .gmail }
        if ["icloud.com", "me.com", "mac.com"].contains(domain) { return .icloud }
        if ["outlook.com", "hotmail.com", "live.com", "msn.com"].contains(domain) || domain.hasPrefix("outlook.") || domain.hasPrefix("hotmail.") { return .outlook }
        if domain.hasPrefix("yahoo.") || domain == "ymail.com" || domain == "rocketmail.com" { return .yahoo }
        return .custom
    }
}

struct ServerSettings: Codable, Hashable {
    var imapHost: String
    var imapPort: Int
    var imapSecurity: TransportSecurity
    var smtpHost: String
    var smtpPort: Int
    var smtpSecurity: TransportSecurity
}

enum AuthKind: String, Codable { case password, oauthMicrosoft, oauthGoogle }

// MARK: - Account

struct Account: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var provider: MailProvider
    var displayName: String       // the sender name
    var email: String
    var username: String          // IMAP/SMTP login (usually the email)
    var authKind: AuthKind
    var servers: ServerSettings
    var signature: String = ""
    var colorIndex: Int = 0
    var notificationsEnabled: Bool = true

    var address: MailAddress { MailAddress(name: displayName, email: email) }

    var accentColor: Color {
        Account.palette[colorIndex % Account.palette.count]
    }

    static let palette: [Color] = [
        Color(red: 0.23, green: 0.47, blue: 0.96), Color(red: 0.93, green: 0.42, blue: 0.24),
        Color(red: 0.20, green: 0.66, blue: 0.47), Color(red: 0.62, green: 0.35, blue: 0.86),
        Color(red: 0.90, green: 0.30, blue: 0.47), Color(red: 0.12, green: 0.64, blue: 0.76),
    ]
}

// MARK: - Folders

enum FolderRole: String, Codable {
    case inbox, sent, drafts, trash, junk, archive, all, flagged, other

    var symbol: String {
        switch self {
        case .inbox: return "tray"
        case .sent: return "paperplane"
        case .drafts: return "doc"
        case .trash: return "trash"
        case .junk: return "xmark.bin"
        case .archive: return "archivebox"
        case .all: return "tray.2"
        case .flagged: return "flag"
        case .other: return "folder"
        }
    }

    var sortOrder: Int {
        switch self {
        case .inbox: return 0
        case .flagged: return 1
        case .drafts: return 2
        case .sent: return 3
        case .archive: return 4
        case .all: return 5
        case .junk: return 6
        case .trash: return 7
        case .other: return 10
        }
    }
}

struct Folder: Codable, Identifiable, Hashable {
    var accountID: UUID
    var path: String            // server path (modified UTF-7)
    var name: String            // decoded full name
    var delimiter: String?
    var role: FolderRole
    var unread: Int = 0

    var id: String { "\(accountID.uuidString)|\(path)" }

    var displayName: String {
        switch role {
        case .inbox: return "Inbox"
        case .sent: return "Sent"
        case .drafts: return "Drafts"
        case .trash: return "Trash"
        case .junk: return "Junk"
        case .archive: return "Archive"
        case .all: return "All Mail"
        case .flagged: return "Starred"
        case .other:
            if let d = delimiter, !d.isEmpty, let last = name.components(separatedBy: d).last { return last }
            return name
        }
    }

    var depth: Int {
        guard role == .other, let d = delimiter, !d.isEmpty else { return 0 }
        var n = name
        if n.hasPrefix("INBOX" + d) { n = String(n.dropFirst(5 + d.count)) }
        return max(0, n.components(separatedBy: d).count - 1)
    }

    static func role(for mailbox: IMAPMailbox) -> FolderRole {
        if mailbox.name.uppercased() == "INBOX" { return .inbox }
        if mailbox.has("\\Sent") { return .sent }
        if mailbox.has("\\Drafts") { return .drafts }
        if mailbox.has("\\Trash") { return .trash }
        if mailbox.has("\\Junk") { return .junk }
        if mailbox.has("\\Archive") { return .archive }
        if mailbox.has("\\All") { return .all }
        if mailbox.has("\\Flagged") { return .flagged }
        // Fallback by common names when the server lacks SPECIAL-USE.
        let last = mailbox.name.components(separatedBy: mailbox.delimiter ?? "/").last?.lowercased() ?? ""
        switch last {
        case "sent", "sent items", "sent mail", "sent messages": return .sent
        case "drafts", "draft": return .drafts
        case "trash", "deleted items", "deleted messages", "deleted", "bin": return .trash
        case "junk", "spam", "junk e-mail", "bulk mail": return .junk
        case "archive", "archives": return .archive
        default: return .other
        }
    }
}

// MARK: - Messages

struct MessageFlags: OptionSet, Codable, Hashable {
    let rawValue: Int
    static let seen = MessageFlags(rawValue: 1 << 0)
    static let flagged = MessageFlags(rawValue: 1 << 1)
    static let answered = MessageFlags(rawValue: 1 << 2)
    static let draft = MessageFlags(rawValue: 1 << 3)
    static let deleted = MessageFlags(rawValue: 1 << 4)
    static let forwarded = MessageFlags(rawValue: 1 << 5)

    init(rawValue: Int) { self.rawValue = rawValue }

    init(imap: [String]) {
        var f: MessageFlags = []
        for s in imap.map({ $0.lowercased() }) {
            switch s {
            case "\\seen": f.insert(.seen)
            case "\\flagged": f.insert(.flagged)
            case "\\answered": f.insert(.answered)
            case "\\draft": f.insert(.draft)
            case "\\deleted": f.insert(.deleted)
            case "$forwarded": f.insert(.forwarded)
            default: break
            }
        }
        self = f
    }
}

struct MessageSummary: Identifiable, Hashable {
    var accountID: UUID
    var folderPath: String
    var uid: UInt32
    var messageID: String
    var subject: String
    var from: MailAddress
    var to: [MailAddress]
    var cc: [MailAddress]
    var date: Date
    var flags: MessageFlags
    var size: Int
    var snippet: String
    var hasAttachments: Bool
    var inReplyTo: String?
    var references: [String]
    var snoozeUntil: Date?
    /// 0 = nothing found, 1 = caution, 2 = danger (see PhishingShield).
    var risk: Int = 0

    var id: String { "\(accountID.uuidString)|\(folderPath)|\(uid)" }
    var isUnread: Bool { !flags.contains(.seen) }
    var isFlagged: Bool { flags.contains(.flagged) }

    static func make(accountID: UUID, folderPath: String, summary: IMAPSummary) -> MessageSummary {
        var combined = summary.header
        combined.append(summary.textPrefix)
        let parsed = ParsedMessage(data: combined)
        let root = MIMEHeaders(raw: summary.header)
        let ct = HeaderValue(root.raw("Content-Type")).value
        let hasAtt = ct == "multipart/mixed" || !parsed.attachments.filter { !$0.isInline }.isEmpty
        return MessageSummary(
            accountID: accountID, folderPath: folderPath, uid: summary.uid,
            messageID: parsed.messageID ?? "",
            subject: parsed.subject,
            from: parsed.from.first ?? MailAddress(name: "", email: "unknown"),
            to: parsed.to, cc: parsed.cc,
            date: parsed.date ?? summary.internalDate ?? Date(),
            flags: MessageFlags(imap: summary.flags),
            size: summary.size,
            snippet: parsed.snippet,
            hasAttachments: hasAtt,
            inReplyTo: parsed.inReplyTo,
            references: parsed.references,
            snoozeUntil: nil,
            risk: PhishingShield.headerRisk(parsed))
    }
}

// MARK: - Templates

struct MailTemplate: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var subject: String
    var body: String
}
