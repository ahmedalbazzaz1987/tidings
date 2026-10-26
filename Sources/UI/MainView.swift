import SwiftUI
import AppKit

struct MainView: View {
    @EnvironmentObject var store: MailStore
    @EnvironmentObject var prefs: Preferences
    @ViewState private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            if store.accounts.isEmpty {
                WelcomeView()
            } else {
                NavigationSplitView(columnVisibility: $columns) {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
                } content: {
                    Group {
                        if store.selection == .bills { BillsView() } else { MessageListView() }
                    }
                        .navigationSplitViewColumnWidth(min: 320, ideal: 390, max: 560)
                } detail: {
                    DetailContainer()
                }
                .searchable(text: $store.searchText, placement: .toolbar, prompt: "Search mail")
                .onSubmit(of: .search) { store.searchOnServer() }
                // One toolbar for the whole window. It never changes shape when the
                // selection changes, which keeps the message list's scroll area stable.
                .toolbar { toolbarItems }
            }
        }
        .tint(prefs.theme.accent)
        .preferredColorScheme(prefs.colorScheme)
        .sheet(isPresented: $store.showAddAccount) { AddAccountView() }
        .overlay(alignment: .bottom) { ToastView() }
    }
}

extension MainView {
    @ToolbarContentBuilder
    var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            let sel = store.selectedMessages
            let none = sel.isEmpty

            Button { ComposeWindow.open(.new) } label: { Label("New Message", systemImage: "square.and.pencil") }
                .help("New Message (⌘N)")

            Button { store.refreshAll() } label: { Label("Get Mail", systemImage: "arrow.clockwise") }
                .help("Get New Mail (⇧⌘N)")

            Button { store.archive(sel) } label: { Label("Archive", systemImage: "archivebox") }
                .help("Archive (⌃⌘A)")
                .disabled(none)

            Button { store.delete(sel) } label: { Label("Delete", systemImage: "trash") }
                .help("Delete (⌫)")
                .disabled(none)

            Button { store.toggleRead(sel) } label: {
                Label("Read/Unread", systemImage: sel.contains(where: \.isUnread) ? "envelope.open" : "envelope.badge")
            }
            .help("Mark as Read / Unread (⇧⌘U)")
            .disabled(none)

            Button { store.toggleFlag(sel) } label: {
                Label("Star", systemImage: !none && sel.allSatisfy(\.isFlagged) ? "star.fill" : "star")
            }
            .help("Star (⇧⌘L)")
            .disabled(none)

            Menu {
                SnoozeItems(list: sel)
            } label: {
                Label("Snooze", systemImage: "clock")
            }
            .help("Snooze / Remind Me")
            .disabled(none)

            Menu {
                MoveItems(list: sel)
                Divider()
                Button("Move to Junk") { store.markJunk(sel) }
            } label: {
                Label("Move", systemImage: "folder")
            }
            .help("Move to Folder")
            .disabled(none)
        }
    }
}

// MARK: - Toast

struct ToastView: View {
    @EnvironmentObject var store: MailStore
    @EnvironmentObject var prefs: Preferences

    var body: some View {
        if let text = store.toast {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(prefs.theme.gradient)
                Text(text).font(.callout.weight(.medium))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(prefs.theme.accent.opacity(0.25)))
            .shadow(color: .black.opacity(0.15), radius: 14, y: 6)
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: text) {
                try? await Task.sleep(nanoseconds: 2_600_000_000)
                withAnimation(.easeOut(duration: 0.25)) { store.toast = nil }
            }
        }
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    @EnvironmentObject var store: MailStore
    @EnvironmentObject var prefs: Preferences

    var body: some View {
        let theme = prefs.theme
        ZStack {
            // Soft aurora background
            ZStack {
                Circle().fill(theme.colors[0].opacity(0.35)).frame(width: 520).blur(radius: 120).offset(x: -260, y: -200)
                Circle().fill(theme.colors[2].opacity(0.30)).frame(width: 480).blur(radius: 120).offset(x: 280, y: 180)
                Circle().fill(theme.colors[1].opacity(0.20)).frame(width: 380).blur(radius: 110).offset(x: 200, y: -240)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            VStack(spacing: 24) {
                Spacer()
                AppGlyph(size: 112)
                VStack(spacing: 8) {
                    Text("Welcome to Tidings")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("A calm, private home for all your email.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 18) {
                    Feature(symbol: "tray.2.fill", colors: [Color(hex: 0x6366F1), Color(hex: 0x3B82F6)],
                            title: "Every inbox", text: "Gmail, iCloud, Outlook, Yahoo and your own domain in one place.")
                    Feature(symbol: "hand.raised.fill", colors: [Color(hex: 0xEC4899), Color(hex: 0xF43F5E)],
                            title: "Private by design", text: "Trackers and remote images blocked. Passwords stay in your Keychain.")
                    Feature(symbol: "bolt.fill", colors: [Color(hex: 0xF59E0B), Color(hex: 0xF97316)],
                            title: "Light and fast", text: "Native, tiny, instant push. Removes itself cleanly.")
                }
                .frame(maxWidth: 780)
                .padding(.top, 6)
                Button {
                    store.showAddAccount = true
                } label: {
                    Label("Add an Account", systemImage: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                }
                .buttonStyle(GradientButtonStyle(theme: theme))
                Spacer()
                Text("Nothing is sent anywhere except to your own mail servers.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 18)
            }
            .padding(.horizontal, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    struct Feature: View {
        let symbol: String
        let colors: [Color]
        let title: String
        let text: String
        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                IconTile(symbol: symbol, colors: colors, size: 34)
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 160, alignment: .topLeading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
            .shadow(color: .black.opacity(0.06), radius: 12, y: 6)
        }
    }
}

/// The app icon itself, shown on the welcome screen.
struct AppGlyph: View {
    var size: CGFloat
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size * 1.2, height: size * 1.2)
    }
}

// MARK: - Avatar

struct Avatar: View {
    let address: MailAddress
    var size: CGFloat = 34

    var body: some View {
        let (c1, c2) = AvatarPalette.pair(for: address.email)
        Circle()
            .fill(LinearGradient(colors: [c1, c2], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                Text(address.initials)
                    .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            )
            .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
            .frame(width: size, height: size)
    }
}
