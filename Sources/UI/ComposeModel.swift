import SwiftUI
import AppKit

enum ComposeKind {
    case new
    case reply(MessageSummary, all: Bool)
    case forward(MessageSummary)
    case mailto(URL)
}

@MainActor
final class ComposeModel: ObservableObject {
    @Published var fromAccountID: UUID
    @Published var to = ""
    @Published var cc = ""
    @Published var bcc = ""
    @Published var showCcBcc = false
    @Published var subject = ""
    @Published var attachments: [MailAttachment] = []
    @Published var isSending = false
    @Published var errorMessage: String?
    @Published var isPreparing = false

    let textView: NSTextView
    let scrollView: NSScrollView
    private(set) var original: MessageSummary?
    private var inReplyTo: String?
    private var references: [String] = []
    var didSend = false
    var onClose: (() -> Void)?

    static let bodyFont = NSFont(name: "Helvetica Neue", size: 14) ?? NSFont.systemFont(ofSize: 14)

    init(kind: ComposeKind) {
        let store = MailStore.shared
        let defaultAccount: UUID = {
            if case .folder(let a, _) = store.selection { return a }
            return store.accounts.first?.id ?? UUID()
        }()
        fromAccountID = defaultAccount

        scrollView = NSTextView.scrollableTextView()
        textView = scrollView.documentView as! NSTextView
        configureTextView()

        switch kind {
        case .new:
            setBody(signatureBlock(for: defaultAccount), cursorAtStart: true)
        case .mailto(let url):
            parseMailto(url)
            setBody(signatureBlock(for: defaultAccount), cursorAtStart: true, prefix: textView.string)
        case .reply(let m, let all):
            fromAccountID = m.accountID
            original = m
            prepareReply(m, all: all)
        case .forward(let m):
            fromAccountID = m.accountID
            original = m
            prepareForward(m)
        }
    }

    private func configureTextView() {
        textView.isRichText = true
        textView.allowsUndo = true
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.usesFontPanel = true
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.font = ComposeModel.bodyFont
        textView.typingAttributes = [.font: ComposeModel.bodyFont, .foregroundColor: NSColor.textColor]
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
    }

    var account: Account? { MailStore.shared.account(fromAccountID) }

    var hasContent: Bool {
        let body = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let sig = signatureBlock(for: fromAccountID).trimmingCharacters(in: .whitespacesAndNewlines)
        return !to.isEmpty || !subject.isEmpty || !attachments.isEmpty || (!body.isEmpty && body != sig && original == nil)
    }

    // MARK: Body helpers

    private func signatureBlock(for accountID: UUID) -> String {
        guard let sig = MailStore.shared.account(accountID)?.signature, !sig.isEmpty else { return "" }
        return "\n\n-- \n" + sig
    }

    private func setBody(_ text: String, cursorAtStart: Bool, prefix: String = "", quoted: String? = nil) {
        let result = NSMutableAttributedString(string: prefix + text,
                                               attributes: [.font: ComposeModel.bodyFont, .foregroundColor: NSColor.textColor])
        if let quoted {
            let quoteStyle = NSMutableParagraphStyle()
            quoteStyle.headIndent = 12
            quoteStyle.firstLineHeadIndent = 12
            result.append(NSAttributedString(string: quoted, attributes: [
                .font: NSFont(name: "Helvetica Neue", size: 13) ?? NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: quoteStyle,
            ]))
        }
        textView.textStorage?.setAttributedString(result)
        textView.setSelectedRange(NSRange(location: cursorAtStart ? 0 : (textView.string as NSString).length, length: 0))
        textView.typingAttributes = [.font: ComposeModel.bodyFont, .foregroundColor: NSColor.textColor]
    }

    private func parseMailto(_ url: URL) {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        to = comps.path.removingPercentEncoding ?? comps.path
        for item in comps.queryItems ?? [] {
            switch item.name.lowercased() {
            case "subject": subject = item.value ?? ""
            case "cc": cc = item.value ?? ""; showCcBcc = true
            case "bcc": bcc = item.value ?? ""; showCcBcc = true
            case "body": textView.string = item.value ?? ""
            default: break
            }
        }
    }

    private func quoteHeader(_ m: MessageSummary) -> String {
        "On \(m.date.formatted(date: .abbreviated, time: .shortened)), \(m.from.encodedForDisplay) wrote:\n"
    }

    private func prepareReply(_ m: MessageSummary, all: Bool) {
        let store = MailStore.shared
        let me = Set(store.accounts.map { $0.email.lowercased() })
        subject = m.subject.lowercased().hasPrefix("re:") ? m.subject : "Re: " + m.subject
        inReplyTo = m.messageID.isEmpty ? nil : m.messageID
        references = m.references + (m.messageID.isEmpty ? [] : [m.messageID])
        setBody(signatureBlock(for: m.accountID), cursorAtStart: true)
        isPreparing = true
        Task {
            let parsed = try? await store.loadContent(m)
            let replyTo = (parsed?.replyTo.isEmpty == false) ? parsed!.replyTo : [m.from]
            var toList = replyTo
            var ccList: [MailAddress] = []
            if all {
                let others = (parsed?.to ?? m.to) + (parsed?.cc ?? m.cc)
                ccList = others.filter { a in !me.contains(a.email.lowercased()) && !toList.contains { $0.email.lowercased() == a.email.lowercased() } }
            }
            toList = toList.filter { !me.contains($0.email.lowercased()) || toList.count == 1 }
            to = toList.map(\.encodedForDisplay).joined(separator: ", ")
            cc = ccList.map(\.encodedForDisplay).joined(separator: ", ")
            showCcBcc = !cc.isEmpty
            let originalText = parsed.map { $0.textBody ?? $0.htmlBody.map(HTMLText.plainText) ?? "" } ?? m.snippet
            let quoted = "\n\n" + quoteHeader(m) + originalText.components(separatedBy: .newlines).map { "> " + $0 }.joined(separator: "\n")
            setBody(signatureBlock(for: m.accountID), cursorAtStart: true, quoted: quoted)
            isPreparing = false
        }
    }

    private func prepareForward(_ m: MessageSummary) {
        let store = MailStore.shared
        subject = m.subject.lowercased().hasPrefix("fwd:") ? m.subject : "Fwd: " + m.subject
        setBody(signatureBlock(for: m.accountID), cursorAtStart: true)
        isPreparing = true
        Task {
            let parsed = try? await store.loadContent(m)
            var header = "\n\n---------- Forwarded message ----------\n"
            header += "From: \(m.from.encodedForDisplay)\n"
            header += "Date: \(m.date.formatted(date: .complete, time: .shortened))\n"
            header += "Subject: \(m.subject)\n"
            header += "To: \((parsed?.to ?? m.to).map(\.encodedForDisplay).joined(separator: ", "))\n\n"
            let body = parsed.map { $0.textBody ?? $0.htmlBody.map(HTMLText.plainText) ?? "" } ?? m.snippet
            setBody(signatureBlock(for: m.accountID), cursorAtStart: true, quoted: header + body)
            attachments = parsed?.attachments.filter { !$0.isInline } ?? []
            isPreparing = false
        }
    }

    // MARK: Attachments

    func addFiles(_ urls: [URL]) {
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            attachments.append(MailAttachment(filename: url.lastPathComponent,
                                              mimeType: MIMEBuilder.mimeType(forExtension: url.pathExtension),
                                              data: data, contentID: nil, isInline: false))
        }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { addFiles(panel.urls) }
    }

    var attachmentsSize: Int { attachments.reduce(0) { $0 + $1.data.count } }

    // MARK: Formatting

    func toggleTrait(_ trait: NSFontTraitMask) {
        let fm = NSFontManager.shared
        let range = textView.selectedRange()
        if range.length == 0 {
            let font = (textView.typingAttributes[.font] as? NSFont) ?? ComposeModel.bodyFont
            let has = fm.traits(of: font).contains(trait)
            var attrs = textView.typingAttributes
            attrs[.font] = has ? fm.convert(font, toNotHaveTrait: trait) : fm.convert(font, toHaveTrait: trait)
            textView.typingAttributes = attrs
            return
        }
        guard let storage = textView.textStorage, textView.shouldChangeText(in: range, replacementString: nil) else { return }
        let firstFont = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont) ?? ComposeModel.bodyFont
        let add = !fm.traits(of: firstFont).contains(trait)
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { value, sub, _ in
            let f = (value as? NSFont) ?? ComposeModel.bodyFont
            storage.addAttribute(.font, value: add ? fm.convert(f, toHaveTrait: trait) : fm.convert(f, toNotHaveTrait: trait), range: sub)
        }
        storage.endEditing()
        textView.didChangeText()
    }

    func toggleUnderline() {
        let range = textView.selectedRange()
        if range.length == 0 {
            var attrs = textView.typingAttributes
            let on = (attrs[.underlineStyle] as? Int ?? 0) != 0
            attrs[.underlineStyle] = on ? 0 : NSUnderlineStyle.single.rawValue
            textView.typingAttributes = attrs
            return
        }
        guard let storage = textView.textStorage, textView.shouldChangeText(in: range, replacementString: nil) else { return }
        let on = (storage.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int ?? 0) != 0
        if on { storage.removeAttribute(.underlineStyle, range: range) }
        else { storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
        textView.didChangeText()
    }

    func changeSize(by delta: CGFloat) {
        let range = textView.selectedRange()
        guard range.length > 0, let storage = textView.textStorage, textView.shouldChangeText(in: range, replacementString: nil) else {
            var attrs = textView.typingAttributes
            let f = (attrs[.font] as? NSFont) ?? ComposeModel.bodyFont
            attrs[.font] = NSFontManager.shared.convert(f, toSize: max(9, min(48, f.pointSize + delta)))
            textView.typingAttributes = attrs
            return
        }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { value, sub, _ in
            let f = (value as? NSFont) ?? ComposeModel.bodyFont
            storage.addAttribute(.font, value: NSFontManager.shared.convert(f, toSize: max(9, min(48, f.pointSize + delta))), range: sub)
        }
        storage.endEditing()
        textView.didChangeText()
    }

    func insertBullets() {
        let ns = textView.string as NSString
        let lineRange = ns.lineRange(for: textView.selectedRange())
        let lines = ns.substring(with: lineRange).components(separatedBy: "\n")
        let allBulleted = lines.filter { !$0.isEmpty }.allSatisfy { $0.hasPrefix("• ") }
        let newText = lines.enumerated().map { i, l -> String in
            if l.isEmpty && i == lines.count - 1 { return l }
            return allBulleted ? String(l.dropFirst(2)) : (l.hasPrefix("• ") ? l : "• " + l)
        }.joined(separator: "\n")
        if textView.shouldChangeText(in: lineRange, replacementString: newText) {
            textView.textStorage?.replaceCharacters(in: lineRange, with: newText)
            textView.didChangeText()
        }
    }

    func clearFormatting() {
        let range = textView.selectedRange().length > 0 ? textView.selectedRange() : NSRange(location: 0, length: (textView.string as NSString).length)
        guard let storage = textView.textStorage, textView.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.setAttributes([.font: ComposeModel.bodyFont, .foregroundColor: NSColor.textColor], range: range)
        textView.didChangeText()
    }

    func insertTemplate(_ t: MailTemplate) {
        if subject.isEmpty { subject = t.subject }
        textView.insertText(t.body, replacementRange: textView.selectedRange())
    }

    // MARK: Building

    /// Converts the editor contents to HTML, dropping the dynamic text color so
    /// recipients never get white-on-white text from dark mode.
    private func htmlBody() -> String? {
        let attr = NSMutableAttributedString(attributedString: textView.attributedString())
        let full = NSRange(location: 0, length: attr.length)
        attr.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            if let c = value as? NSColor, c == NSColor.textColor || c == NSColor.labelColor {
                attr.removeAttribute(.foregroundColor, range: range)
            } else if let c = value as? NSColor, c == NSColor.secondaryLabelColor {
                attr.addAttribute(.foregroundColor, value: NSColor(calibratedWhite: 0.42, alpha: 1), range: range)
            }
        }
        attr.removeAttribute(.backgroundColor, range: full)
        guard let data = try? attr.data(from: full, documentAttributes: [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]) else { return nil }
        var html = String(decoding: data, as: UTF8.self)
        html = html.replacingOccurrences(of: "<meta name=\"Generator\" content=\"Cocoa HTML Writer\">", with: "")
        html = html.replacingOccurrences(of: "<body>", with: "<body dir=\"auto\">")
        return html
    }

    private func parseRecipients(_ s: String) -> [MailAddress] { MailAddress.parseList(s) }

    func buildMessage() throws -> OutgoingMessage {
        guard let account else { throw MailError.notConfigured("Choose an account to send from.") }
        let toList = parseRecipients(to), ccList = parseRecipients(cc), bccList = parseRecipients(bcc)
        let all = toList + ccList + bccList
        guard !all.isEmpty else { throw MailError.notConfigured("Add at least one recipient.") }
        if let bad = all.first(where: { !MailAddress.isValidEmail($0.email) }) {
            throw MailError.notConfigured("“\(bad.email)” doesn’t look like a valid email address.")
        }
        var msg = OutgoingMessage(from: account.address)
        msg.to = toList
        msg.cc = ccList
        msg.bcc = bccList
        msg.subject = subject
        msg.text = textView.string
        msg.html = htmlBody()
        msg.attachments = attachments
        msg.inReplyTo = inReplyTo
        msg.references = references
        return msg
    }

    func send() async -> Bool {
        errorMessage = nil
        let msg: OutgoingMessage
        do { msg = try buildMessage() } catch { errorMessage = error.localizedDescription; return false }
        if subject.trimmingCharacters(in: .whitespaces).isEmpty {
            let alert = NSAlert()
            alert.messageText = "Send without a subject?"
            alert.addButton(withTitle: "Send")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return false }
        }
        isSending = true
        defer { isSending = false }
        do {
            try await MailStore.shared.send(msg, accountID: fromAccountID, replyingTo: original)
            didSend = true
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func saveDraft() async -> Bool {
        guard let account else { return false }
        var msg = OutgoingMessage(from: account.address)
        msg.to = parseRecipients(to)
        msg.cc = parseRecipients(cc)
        msg.bcc = parseRecipients(bcc)
        msg.subject = subject
        msg.text = textView.string
        msg.html = htmlBody()
        msg.attachments = attachments
        msg.inReplyTo = inReplyTo
        msg.references = references
        do {
            try await MailStore.shared.saveDraft(msg, accountID: fromAccountID)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
