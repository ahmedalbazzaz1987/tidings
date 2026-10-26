import SwiftUI
import AppKit
import WebKit
import QuickLookUI
import UniformTypeIdentifiers

struct DetailContainer: View {
    @EnvironmentObject var store: MailStore
    @EnvironmentObject var prefs: Preferences

    var body: some View {
        let selected = store.selectedMessages
        Group {
            if selected.count == 1, let m = selected.first {
                MessageReaderView(summary: m)
                    .id(m.id)
            } else if selected.count > 1 {
                MultiSelectionView(list: selected)
            } else {
                VStack(spacing: 14) {
                    ZStack {
                        Circle().fill(prefs.theme.softGradient).frame(width: 110, height: 110)
                        Image(systemName: "envelope.open.fill")
                            .font(.system(size: 44, weight: .medium))
                            .foregroundStyle(prefs.theme.gradient)
                    }
                    Text("No Message Selected")
                        .font(.title3.weight(.semibold))
                    Text(store.totalInboxUnread > 0 ? "\(store.totalInboxUnread) unread in your inboxes" : "You’re all caught up")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .clearsToolbar()
        .background(ZStack { Color(nsColor: .windowBackgroundColor); prefs.theme.softGradient.opacity(0.5) })
    }
}

private struct MultiSelectionView: View {
    @EnvironmentObject var store: MailStore
    let list: [MessageSummary]

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                ForEach(0..<min(3, list.count), id: \.self) { i in
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                        .frame(width: 150, height: 100)
                        .rotationEffect(.degrees(Double(i) * 5 - 5))
                        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                }
                Text("\(list.count)").font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(Preferences.shared.theme.gradient)
            }
            Text("\(list.count) messages selected").font(.title3).foregroundStyle(.secondary)
            HStack {
                Button { store.archive(list) } label: { Label("Archive", systemImage: "archivebox") }
                Button { store.toggleRead(list) } label: { Label("Read / Unread", systemImage: "envelope.badge") }
                Button { store.toggleFlag(list) } label: { Label("Star", systemImage: "star") }
                Button(role: .destructive) { store.delete(list) } label: { Label("Delete", systemImage: "trash") }
            }
            .buttonStyle(PillButtonStyle(theme: Preferences.shared.theme))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Reader

struct MessageReaderView: View {
    @EnvironmentObject var store: MailStore
    @EnvironmentObject var prefs: Preferences
    @Environment(\.colorScheme) private var colorScheme
    let summary: MessageSummary

    @ViewState private var parsed: ParsedMessage? = nil
    @ViewState private var error: String? = nil
    @ViewState private var allowRemoteOnce = false
    @ViewState private var showDetails = false
    @ViewState private var report: SecurityReport? = nil
    @ViewState private var warningDismissed = false
    @EnvironmentObject var bills: BillRadar

    private var senderTrusted: Bool {
        prefs.trustedSenders.contains(summary.from.email.lowercased())
    }

    private var remoteAllowed: Bool { prefs.loadRemoteImages || allowRemoteOnce || senderTrusted }

    var body: some View {
        let theme = prefs.theme
        VStack(spacing: 0) {
            header(theme)
            if let report, !report.isClean, !warningDismissed {
                SecurityBanner(report: report,
                               onSafe: { withAnimation { warningDismissed = true } },
                               onJunk: { store.markJunk([summary]) })
            }
            if let bill = bills.bill(for: summary.id) {
                BillCard(bill: bill)
            }
            if let parsed {
                if MailHTML.hasRemoteContent(parsed) && !remoteAllowed {
                    privacyBanner(theme)
                }
                if !parsed.attachments.filter({ !$0.isInline }).isEmpty {
                    AttachmentStrip(attachments: parsed.attachments.filter { !$0.isInline })
                }
                MailWebView(html: MailHTML.render(parsed, allowRemote: remoteAllowed && (report?.level ?? .caution) != .danger,
                                                  blockTrackers: prefs.blockTrackers, dark: colorScheme == .dark),
                            suspiciousHosts: report?.suspiciousHosts ?? [])
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            } else if let error {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 34)).foregroundStyle(.orange)
                    Text("Couldn’t load this message").font(.headline)
                    Text(error).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Try Again") { Task { await load() } }.buttonStyle(PillButtonStyle(theme: theme))
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text(summary.snippet).foregroundStyle(.secondary).lineLimit(4)
                    ProgressView().controlSize(.small)
                }
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                theme.softGradient.opacity(0.5)
            }
        )
        .task(id: summary.id) { await load() }
    }

    private func load() async {
        error = nil
        do {
            let content = try await store.loadContent(summary)
            parsed = content
            let analysis = PhishingShield.analyze(content)
            report = analysis
            store.updateRisk(summary, risk: analysis.level?.rawValue ?? 0)
            if prefs.markReadOnOpen && summary.isUnread {
                try? await Task.sleep(nanoseconds: 600_000_000)
                if store.selectedIDs.contains(summary.id) || store.selectedIDs.isEmpty {
                    store.setRead([summary], read: true)
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Header

    private func header(_ theme: AppTheme) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(summary.subject.isEmpty ? "(No Subject)" : summary.subject)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if summary.isFlagged {
                    Image(systemName: "star.fill").foregroundStyle(Color(hex: 0xF59E0B))
                }
            }
            HStack(alignment: .center, spacing: 12) {
                Avatar(address: summary.from, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(summary.from.displayName).font(.system(size: 14, weight: .semibold))
                        if !summary.from.name.isEmpty {
                            Text(summary.from.email).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .textSelection(.enabled)
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showDetails.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text("to " + recipientLine).lineLimit(showDetails ? nil : 1)
                            Image(systemName: showDetails ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold))
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(summary.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                        .font(.system(size: 12, weight: .semibold))
                    Text(summary.date.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if showDetails {
                VStack(alignment: .leading, spacing: 4) {
                    if !(parsed?.cc ?? summary.cc).isEmpty {
                        Text("Cc: " + (parsed?.cc ?? summary.cc).map(\.encodedForDisplay).joined(separator: ", "))
                            .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let acc = store.account(summary.accountID) {
                        Text("Account: \(acc.email) · Folder: \(store.folders[acc.id]?.first(where: { $0.path == summary.folderPath })?.displayName ?? summary.folderPath)")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, 56)
            }
            HStack(spacing: 8) {
                Button { ComposeWindow.open(.reply(summary, all: false)) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left.fill") }
                    .buttonStyle(GradientButtonStyle(theme: theme))
                Button { ComposeWindow.open(.reply(summary, all: true)) } label: { Label("Reply All", systemImage: "arrowshape.turn.up.left.2") }
                    .buttonStyle(PillButtonStyle(theme: theme))
                Button { ComposeWindow.open(.forward(summary)) } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
                    .buttonStyle(PillButtonStyle(theme: theme))
                Spacer()
                if let unsub = parsed?.listUnsubscribe, let url = MailHTML.unsubscribeURL(unsub) {
                    Button { NSWorkspace.shared.open(url) } label: { Label("Unsubscribe", systemImage: "hand.wave") }
                        .buttonStyle(PillButtonStyle(theme: theme))
                        .help("Opens the sender’s unsubscribe page in your browser")
                }
                Menu {
                    SnoozeMenu(list: [summary])
                    MoveMenu(list: [summary])
                    Divider()
                    Button("Mark as Unread") { store.setRead([summary], read: false) }
                    Button("Move to Junk") { store.markJunk([summary]) }
                    Button("Open in New Window") { ReaderWindow.open(summary) }
                    Divider()
                    Button("View Source") { ReaderWindow.openSource(summary) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 30, height: 26)
                        .background(Circle().fill(theme.accent.opacity(0.12)))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions")
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
        )
        .padding(14)
    }

    private var recipientLine: String {
        let to = parsed?.to ?? summary.to
        if to.isEmpty { return "undisclosed recipients" }
        return to.map { $0.name.isEmpty ? $0.email : $0.name }.joined(separator: ", ")
    }

    private func privacyBanner(_ theme: AppTheme) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.gradient)
            Text("Remote images blocked — the sender can’t see that you opened this.")
                .font(.callout)
            Spacer()
            Button("Load Once") { allowRemoteOnce = true }
                .buttonStyle(PillButtonStyle(theme: theme))
            Button("Always for Sender") {
                var t = prefs.trustedSenders
                t.insert(summary.from.email.lowercased())
                prefs.trustedSenders = t
            }
            .buttonStyle(PillButtonStyle(theme: theme))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.softGradient))
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }
}

extension MailAddress {
    var encodedForDisplay: String { name.isEmpty ? email : "\(name) <\(email)>" }
}

// MARK: - Attachments

struct AttachmentStrip: View {
    let attachments: [MailAttachment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { a in
                    AttachmentChip(attachment: a)
                }
                if attachments.count > 1 {
                    Button("Save All…") { AttachmentActions.saveAll(attachments) }
                        .buttonStyle(.link)
                        .font(.callout)
                        .padding(.leading, 4)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
        }
    }
}

private struct AttachmentChip: View {
    let attachment: MailAttachment
    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(for: AttachmentActions.contentType(attachment)))
                .resizable()
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename).font(.callout).lineLimit(1).truncationMode(.middle)
                Text(attachment.sizeText).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 170, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9).fill(hovering ? Color.primary.opacity(0.08) : Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.separator.opacity(0.6)))
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { AttachmentActions.open(attachment) }
        .onTapGesture { AttachmentActions.quickLook(attachment) }
        .contextMenu {
            Button("Open") { AttachmentActions.open(attachment) }
            Button("Quick Look") { AttachmentActions.quickLook(attachment) }
            Button("Save As…") { AttachmentActions.save(attachment) }
        }
        .help("Click to preview, double-click to open")
    }
}

@MainActor
enum AttachmentActions {
    static func contentType(_ a: MailAttachment) -> UTType {
        let ext = (a.filename as NSString).pathExtension
        return UTType(filenameExtension: ext) ?? UTType(mimeType: a.mimeType) ?? .data
    }

    /// Writes to a private temporary folder that is emptied when Tidings quits.
    static func tempURL(_ a: MailAttachment) -> URL? {
        let dir = AppPaths.attachmentsTemp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = a.filename.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let url = dir.appendingPathComponent(safe.isEmpty ? "attachment" : safe)
        do { try a.data.write(to: url) } catch { return nil }
        return url
    }

    static func open(_ a: MailAttachment) {
        guard let url = tempURL(a) else { return }
        NSWorkspace.shared.open(url)
    }

    static func save(_ a: MailAttachment) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = a.filename
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { try? a.data.write(to: url) }
    }

    static func saveAll(_ list: [MailAttachment]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        for a in list {
            var url = dir.appendingPathComponent(a.filename)
            var n = 2
            while FileManager.default.fileExists(atPath: url.path) {
                let base = (a.filename as NSString).deletingPathExtension
                let ext = (a.filename as NSString).pathExtension
                url = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
                n += 1
            }
            try? a.data.write(to: url)
        }
    }

    static func quickLook(_ a: MailAttachment) {
        guard let url = tempURL(a) else { return }
        QuickLookCoordinator.shared.show(url)
    }
}

final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLookCoordinator()
    private var url: URL?

    func show(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { url as NSURL? }
}


// MARK: - Phishing shield banner

struct SecurityBanner: View {
    let report: SecurityReport
    let onSafe: () -> Void
    let onJunk: () -> Void
    @ViewState private var expanded = true

    private var danger: Bool { report.level == .danger }
    private var tint: Color { danger ? Color(hex: 0xE11D48) : Color(hex: 0xEA580C) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: danger ? "exclamationmark.shield.fill" : "shield.lefthalf.filled")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(danger ? "This message looks like a scam" : "Be careful with this message")
                        .font(.system(size: 13.5, weight: .bold))
                    Text(danger ? "Don’t click links, open attachments or reply with personal details."
                                : "Something about it doesn’t add up. Check before you click.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(report.findings) { f in
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(f.level == .danger ? Color(hex: 0xE11D48) : Color(hex: 0xEA580C))
                                .frame(width: 7, height: 7)
                                .padding(.top, 5)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.title).font(.system(size: 12.5, weight: .semibold))
                                Text(f.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(.leading, 30)
                HStack(spacing: 8) {
                    Spacer()
                    Button("I Trust This Message", action: onSafe)
                        .buttonStyle(.borderless)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Button {
                        onJunk()
                    } label: {
                        Label("Move to Junk", systemImage: "xmark.bin.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(tint))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(tint.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.35)))
        )
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }
}
