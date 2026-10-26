import SwiftUI

/// The sidebar. Built on ScrollView (not List) for the same reason as the message
/// list: a List here could end up scrolled underneath the toolbar with no way back.
struct SidebarView: View {
    @EnvironmentObject var store: MailStore
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var radar: BillRadar
    @ViewState private var collapsed: Set<UUID> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                SectionTitle(text: "Favorites")
                item(.allInboxes) {
                    SidebarRow(title: "All Inboxes", symbol: "tray.2.fill", colors: prefs.theme.colors,
                               count: store.totalInboxUnread, highlightCount: true)
                }
                item(.flagged) {
                    SidebarRow(title: "Starred", symbol: "star.fill", colors: [Color(hex: 0xFBBF24), Color(hex: 0xF59E0B)], count: 0)
                }
                item(.snoozed) {
                    SidebarRow(title: "Snoozed", symbol: "clock.fill", colors: [Color(hex: 0xA78BFA), Color(hex: 0x7C3AED)], count: 0)
                }
                item(.bills) {
                    SidebarRow(title: "Bills", symbol: "doc.text.fill", colors: [Color(hex: 0x34D399), Color(hex: 0x059669)],
                               count: radar.attentionCount, highlightCount: true)
                }

                ForEach(store.accounts) { account in
                    AccountHeader(account: account, collapsed: collapsed.contains(account.id)) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            if collapsed.contains(account.id) { collapsed.remove(account.id) } else { collapsed.insert(account.id) }
                        }
                    }
                    .padding(.top, 12)
                    if !collapsed.contains(account.id) {
                        ForEach(store.folders[account.id] ?? []) { folder in
                            item(.folder(account.id, folder.path)) {
                                SidebarRow(title: folder.displayName,
                                           symbol: folder.role.filledSymbol,
                                           colors: folder.role == .inbox ? [account.accentColor.opacity(0.85), account.accentColor] : folder.role.tileColors,
                                           count: folder.role == .inbox || folder.role == .other ? folder.unread : 0,
                                           indent: folder.depth)
                            }
                            .dropDestination(for: String.self) { ids, _ in
                                let list = store.messages.filter { ids.contains($0.id) }
                                store.move(list, to: folder)
                                return !list.isEmpty
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .clearsToolbar()
        .onChange(of: store.selection) { item in
            if case .folder(let a, let p) = item { store.syncFolder(a, p) }
        }
        .safeAreaInset(edge: .bottom) {
            SidebarFooter()
        }
    }

    /// A selectable sidebar row.
    private func item<Content: View>(_ tag: SidebarItem, @ViewBuilder _ content: () -> Content) -> some View {
        SelectableRow(selected: store.selection == tag, theme: prefs.theme) {
            content()
        }
        .onTapGesture { store.selection = tag }
    }
}

private struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 8)
            .padding(.bottom, 2)
    }
}

private struct SelectableRow<Content: View>: View {
    let selected: Bool
    let theme: AppTheme
    @ViewBuilder var content: Content
    @ViewState private var hover = false

    var body: some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? theme.accent.opacity(0.22) : (hover ? Color.primary.opacity(0.06) : Color.clear))
            )
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

extension FolderRole {
    var filledSymbol: String {
        switch self {
        case .inbox: return "tray.fill"
        case .sent: return "paperplane.fill"
        case .drafts: return "doc.fill"
        case .trash: return "trash.fill"
        case .junk: return "xmark.bin.fill"
        case .archive: return "archivebox.fill"
        case .all: return "tray.2.fill"
        case .flagged: return "star.fill"
        case .other: return "folder.fill"
        }
    }

    var tileColors: [Color] {
        switch self {
        case .inbox: return [Color(hex: 0x60A5FA), Color(hex: 0x3B82F6)]
        case .sent: return [Color(hex: 0x38BDF8), Color(hex: 0x0284C7)]
        case .drafts: return [Color(hex: 0x94A3B8), Color(hex: 0x64748B)]
        case .trash: return [Color(hex: 0xFB7185), Color(hex: 0xE11D48)]
        case .junk: return [Color(hex: 0xFDBA74), Color(hex: 0xEA580C)]
        case .archive: return [Color(hex: 0x4ADE80), Color(hex: 0x16A34A)]
        case .all: return [Color(hex: 0x818CF8), Color(hex: 0x4F46E5)]
        case .flagged: return [Color(hex: 0xFBBF24), Color(hex: 0xF59E0B)]
        case .other: return [Color(hex: 0x5EEAD4), Color(hex: 0x0D9488)]
        }
    }
}

private struct AccountHeader: View {
    @EnvironmentObject var store: MailStore
    let account: Account
    let collapsed: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            IconTile(symbol: account.provider.symbol,
                     colors: [account.provider.tint.opacity(0.85), account.provider.tint], size: 16)
            Text(account.email)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if store.syncing.contains(account.id) {
                ProgressView().controlSize(.mini)
            } else if let err = store.errors[account.id] {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(err)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(collapsed ? 0 : 90))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .contextMenu {
            Button("Get New Mail") { store.refresh(accountID: account.id, includeFolders: true) }
            Button(collapsed ? "Show Folders" : "Hide Folders", action: toggle)
            Divider()
            Text(account.email)
        }
    }
}

struct SidebarRow: View {
    @EnvironmentObject var prefs: Preferences
    let title: String
    let symbol: String
    let colors: [Color]
    let count: Int
    var indent: Int = 0
    var highlightCount = false

    var body: some View {
        HStack(spacing: 9) {
            IconTile(symbol: symbol, colors: colors, size: 22)
            Text(title).lineLimit(1)
            Spacer(minLength: 4)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(highlightCount ? Color.white : Color.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background {
                        if highlightCount { Capsule().fill(prefs.theme.gradient) }
                        else { Capsule().fill(Color.primary.opacity(0.08)) }
                    }
            }
        }
        .padding(.leading, CGFloat(indent) * 14)
        .padding(.vertical, 1)
    }
}

private struct SidebarFooter: View {
    @EnvironmentObject var store: MailStore
    @EnvironmentObject var prefs: Preferences

    var body: some View {
        HStack(spacing: 8) {
            if !store.syncing.isEmpty {
                ProgressView().controlSize(.small)
                Text("Checking for mail…").font(.caption).foregroundStyle(.secondary)
            } else if !store.errors.isEmpty {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
                Text(store.errors.values.first ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(store.errors.values.joined(separator: "\n"))
            } else {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(prefs.theme.gradient)
                Text("Up to date").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { store.showAddAccount = true } label: { Image(systemName: "person.crop.circle.badge.plus") }
                .buttonStyle(.borderless)
                .help("Add Account")
            Button { store.refreshAll() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Get New Mail (⇧⌘N)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
