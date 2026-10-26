import SwiftUI
import AppKit

/// The message list. Built on ScrollView + LazyVStack (rather than List) so its
/// scroll area never ends up underneath the toolbar, and so rows can be styled freely.
struct MessageListView: View {
    @EnvironmentObject var store: MailStore
    @EnvironmentObject var prefs: Preferences
    @StateObject private var keys = ListKeyMonitor()
    @ViewState private var anchorID: String? = nil

    private var sections: [(String, [MessageSummary])] {
        let cal = Calendar.current
        let now = Date()
        var order: [String] = []
        var groups: [String: [MessageSummary]] = [:]
        for m in store.messages {
            let key: String
            if cal.isDateInToday(m.date) { key = "Today" }
            else if cal.isDateInYesterday(m.date) { key = "Yesterday" }
            else if let d = cal.dateComponents([.day], from: m.date, to: now).day, d < 7 { key = "This Week" }
            else if cal.isDate(m.date, equalTo: now, toGranularity: .month) { key = "Earlier This Month" }
            else if cal.isDate(m.date, equalTo: now, toGranularity: .year) {
                key = m.date.formatted(.dateTime.month(.wide))
            } else {
                key = m.date.formatted(.dateTime.year())
            }
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(m)
        }
        return order.map { ($0, groups[$0]!) }
    }

    var body: some View {
        VStack(spacing: 0) {
            FilterBar()
            if store.messages.isEmpty {
                EmptyListView()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]) {
                            ForEach(sections, id: \.0) { section in
                                Section {
                                    ForEach(section.1) { m in
                                        MessageRow(message: m,
                                                   selected: store.selectedIDs.contains(m.id),
                                                   showAccount: store.accounts.count > 1)
                                            .id(m.id)
                                            .onTapGesture { click(m) }
                                            .contextMenu { MessageActions(list: targets(for: m)) }
                                            .draggable(m.id)
                                            .onAppear {
                                                if m.id == store.messages.last?.id { store.loadOlder() }
                                            }
                                    }
                                } header: {
                                    SectionHeader(title: section.0)
                                }
                            }
                            footer
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 12)
                        .background(PersistentScroller())
                    }
                    .scrollIndicators(.visible)
                    .onAppear {
                        keys.install { key in handleKey(key, proxy: proxy) }
                    }
                    .onDisappear { keys.remove() }
                }
            }
        }
        .clearsToolbar()
        .background(listBackground)
        .navigationTitle(store.selectionTitle)
        .navigationSubtitle(subtitle)
        .overlay(alignment: .top) {
            if store.isSearchingServer {
                ProgressView("Searching server…")
                    .controlSize(.small)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 52)
            }
        }
    }

    private var listBackground: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            prefs.theme.softGradient.opacity(0.35)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if store.canLoadOlder {
            HStack {
                Spacer()
                if store.loadingOlder {
                    ProgressView().controlSize(.small)
                    Text("Loading older messages…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Load Older Messages") { store.loadOlder() }
                        .buttonStyle(PillButtonStyle(theme: prefs.theme))
                }
                Spacer()
            }
            .padding(.vertical, 14)
        }
    }

    private var subtitle: String {
        let unread = store.messages.filter(\.isUnread).count
        if !store.searchText.isEmpty { return "\(store.messages.count) results — press Return to search the server" }
        return unread > 0 ? "\(unread) unread" : "\(store.messages.count) messages"
    }

    // MARK: Selection

    /// Right-clicking a row that is part of the selection acts on the whole selection.
    private func targets(for m: MessageSummary) -> [MessageSummary] {
        store.selectedIDs.contains(m.id) ? store.selectedMessages : [m]
    }

    private func click(_ m: MessageSummary) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if store.selectedIDs.contains(m.id) { store.selectedIDs.remove(m.id) } else { store.selectedIDs.insert(m.id) }
            anchorID = m.id
        } else if flags.contains(.shift), let anchor = anchorID,
                  let a = store.messages.firstIndex(where: { $0.id == anchor }),
                  let b = store.messages.firstIndex(where: { $0.id == m.id }) {
            store.selectedIDs = Set(store.messages[min(a, b)...max(a, b)].map(\.id))
        } else {
            store.selectedIDs = [m.id]
            anchorID = m.id
        }
        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
            ReaderWindow.open(m)
        }
    }

    private func handleKey(_ key: ListKeyMonitor.Key, proxy: ScrollViewProxy) {
        let list = store.messages
        guard !list.isEmpty else { return }
        switch key {
        case .up, .down:
            let current = list.firstIndex { store.selectedIDs.contains($0.id) && $0.id == (anchorID ?? $0.id) }
                ?? list.firstIndex { store.selectedIDs.contains($0.id) }
            var next: Int
            if let current { next = key == .up ? max(0, current - 1) : min(list.count - 1, current + 1) }
            else { next = 0 }
            if next == current { next = current ?? 0 }
            let id = list[next].id
            store.selectedIDs = [id]
            anchorID = id
            withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: nil) }
        case .delete:
            store.delete(store.selectedMessages)
        case .open:
            if let m = store.selectedMessages.first { ReaderWindow.open(m) }
        }
    }
}

// MARK: - Keyboard

/// Arrow keys / Delete / Return for the list, without stealing keys from text fields
/// or the message body.
final class ListKeyMonitor: ObservableObject {
    enum Key { case up, down, delete, open }
    private var monitor: Any?

    func install(_ handler: @escaping (Key) -> Void) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window = event.window, window.isKeyWindow, window.attachedSheet == nil,
                  !(window is NSPanel) else { return event }
            // Compose/reader windows are tagged "tidings.*"; the Settings window has its own id.
            if let id = window.identifier?.rawValue, id.hasPrefix("tidings.") || id.contains("Settings") { return event }
            if let responder = window.firstResponder {
                if responder is NSText { return event }                       // text fields & editors
                let name = String(describing: type(of: responder))
                if name.contains("WK") || name.contains("Search") { return event } // message body, search field
            }
            let mods = event.modifierFlags.intersection([.command, .option, .control])
            guard mods.isEmpty else { return event }
            switch event.keyCode {
            case 126: handler(.up); return nil
            case 125: handler(.down); return nil
            case 51, 117: handler(.delete); return nil
            case 36: handler(.open); return nil
            default: return event
            }
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { remove() }
}

// MARK: - Pieces

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
    }
}

private struct FilterBar: View {
    @EnvironmentObject var store: MailStore
    @EnvironmentObject var prefs: Preferences

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ListFilter.allCases) { f in
                    let on = store.filter == f
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { store.filter = f }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: f.chipSymbol).font(.system(size: 11, weight: .semibold))
                            Text(f.rawValue).font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(on ? Color.white : Color.primary.opacity(0.75))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background {
                            if on { Capsule().fill(prefs.theme.gradient) }
                            else { Capsule().fill(Color.primary.opacity(0.06)) }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

extension ListFilter {
    var chipSymbol: String {
        switch self {
        case .all: return "tray.full"
        case .unread: return "circle.fill"
        case .flagged: return "star.fill"
        case .attachments: return "paperclip"
        }
    }
}

private struct EmptyListView: View {
    @EnvironmentObject var store: MailStore
    @EnvironmentObject var prefs: Preferences

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(prefs.theme.softGradient).frame(width: 96, height: 96)
                Image(systemName: store.searchText.isEmpty ? (store.filter == .all ? "sparkles" : "line.3.horizontal.decrease") : "magnifyingglass")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(prefs.theme.gradient)
            }
            Text(store.searchText.isEmpty ? (store.syncing.isEmpty ? "All clear" : "Loading…") : "No Results")
                .font(.title3.weight(.semibold))
            if store.searchText.isEmpty && store.filter == .all && store.syncing.isEmpty {
                Text("Nothing here right now.").foregroundStyle(.secondary)
            }
            if !store.searchText.isEmpty {
                Button("Search on Server") { store.searchOnServer() }.buttonStyle(PillButtonStyle(theme: prefs.theme))
            } else if store.filter != .all {
                Button("Show All Messages") { store.filter = .all }.buttonStyle(PillButtonStyle(theme: prefs.theme))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MessageRow: View {
    @EnvironmentObject var store: MailStore
    @EnvironmentObject var prefs: Preferences
    let message: MessageSummary
    let selected: Bool
    let showAccount: Bool
    @ViewState private var hovering = false

    var body: some View {
        let compact = prefs.density == "compact"
        let theme = prefs.theme
        HStack(alignment: .top, spacing: 11) {
            if !compact {
                Avatar(address: message.from, size: 38)
                    .padding(.top, 1)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if compact && message.isUnread {
                        Circle().fill(theme.gradient).frame(width: 7, height: 7)
                    }
                    Text(message.from.displayName)
                        .font(.system(size: 13.5, weight: message.isUnread ? .bold : .medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if message.flags.contains(.answered) {
                        Image(systemName: "arrowshape.turn.up.left.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if message.isFlagged {
                        Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(Color(hex: 0xF59E0B))
                    }
                    Text(MessageRow.shortDate(message.date))
                        .font(.system(size: 11.5, weight: message.isUnread ? .semibold : .regular))
                        .foregroundStyle(message.isUnread ? theme.accent : Color.secondary)
                }
                Text(message.subject.isEmpty ? "(No Subject)" : message.subject)
                    .font(.system(size: 12.5, weight: message.isUnread ? .semibold : .regular))
                    .foregroundStyle(message.isUnread ? Color.primary : Color.primary.opacity(0.8))
                    .lineLimit(1)
                if prefs.previewLines > 0 && !compact && !message.snippet.isEmpty {
                    Text(message.snippet)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(prefs.previewLines)
                        .fixedSize(horizontal: false, vertical: true)
                }
                chips
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, compact ? 6 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background(theme))
        .overlay(alignment: .leading) {
            if message.isUnread && !compact {
                Capsule().fill(theme.gradient).frame(width: 3.5).padding(.vertical, 12).padding(.leading, 2)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if hovering && prefs.showHoverActions {
                HoverActions(message: message).padding(8)
                    .transition(.opacity)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }

    @ViewBuilder
    private var chips: some View {
        let snoozed = (message.snoozeUntil ?? .distantPast) > Date()
        if showAccount || message.hasAttachments || snoozed || message.risk > 0 {
            HStack(spacing: 6) {
                if message.risk > 0 {
                    Chip(text: message.risk >= 2 ? "Suspicious" : "Caution", symbol: "exclamationmark.shield.fill",
                         color: message.risk >= 2 ? Color(hex: 0xE11D48) : Color(hex: 0xEA580C))
                }
                if showAccount, let acc = store.account(message.accountID) {
                    Chip(text: acc.email, symbol: nil, color: acc.accentColor)
                }
                if message.hasAttachments {
                    Chip(text: "Attachment", symbol: "paperclip", color: .secondary)
                }
                if snoozed, let s = message.snoozeUntil {
                    Chip(text: s.formatted(date: .abbreviated, time: .shortened), symbol: "clock", color: .purple)
                }
            }
            .padding(.top, 3)
        }
    }

    @ViewBuilder
    private func background(_ theme: AppTheme) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        if selected {
            shape.fill(LinearGradient(colors: theme.colors.map { $0.opacity(0.22) }, startPoint: .leading, endPoint: .trailing))
                .overlay(shape.strokeBorder(theme.accent.opacity(0.45), lineWidth: 1))
        } else if hovering {
            shape.fill(Color.primary.opacity(0.05))
        } else {
            shape.fill(Color.clear)
        }
    }

    static func shortDate(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 7 {
            return d.formatted(.dateTime.weekday(.wide))
        }
        if cal.isDate(d, equalTo: Date(), toGranularity: .year) { return d.formatted(.dateTime.day().month(.abbreviated)) }
        return d.formatted(date: .numeric, time: .omitted)
    }
}

private struct Chip: View {
    let text: String
    let symbol: String?
    let color: Color
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            else { Circle().fill(color).frame(width: 6, height: 6) }
            Text(text).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(symbol == nil ? Color.secondary : color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}

/// Quick actions that appear on the row under the pointer.
private struct HoverActions: View {
    @EnvironmentObject var store: MailStore
    let message: MessageSummary

    var body: some View {
        HStack(spacing: 2) {
            action(message.isUnread ? "envelope.open" : "envelope.badge", "Mark as Read/Unread") { store.toggleRead([message]) }
            action(message.isFlagged ? "star.fill" : "star", "Star") { store.toggleFlag([message]) }
            action("archivebox", "Archive") { store.archive([message]) }
            action("trash", "Delete") { store.delete([message]) }
        }
        .padding(3)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }

    private func action(_ symbol: String, _ help: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

// MARK: - Shared action menus

struct MessageActions: View {
    @EnvironmentObject var store: MailStore
    let list: [MessageSummary]

    var body: some View {
        if let first = list.first {
            if list.count == 1 {
                Button { ComposeWindow.open(.reply(first, all: false)) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                Button { ComposeWindow.open(.reply(first, all: true)) } label: { Label("Reply All", systemImage: "arrowshape.turn.up.left.2") }
                Button { ComposeWindow.open(.forward(first)) } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
                Button { ReaderWindow.open(first) } label: { Label("Open in New Window", systemImage: "macwindow") }
                Divider()
            }
            Button { store.toggleRead(list) } label: {
                Label(list.contains(where: \.isUnread) ? "Mark as Read" : "Mark as Unread", systemImage: "envelope.badge")
            }
            Button { store.toggleFlag(list) } label: {
                Label(list.allSatisfy(\.isFlagged) ? "Remove Star" : "Star", systemImage: "star")
            }
            SnoozeMenu(list: list)
            Divider()
            Button { store.archive(list) } label: { Label("Archive", systemImage: "archivebox") }
            MoveMenu(list: list)
            Button { store.markJunk(list) } label: { Label("Move to Junk", systemImage: "xmark.bin") }
            Button(role: .destructive) { store.delete(list) } label: { Label("Delete", systemImage: "trash") }
        }
    }
}

struct MoveItems: View {
    @EnvironmentObject var store: MailStore
    let list: [MessageSummary]

    var body: some View {
        let accountIDs = Set(list.map(\.accountID))
        if accountIDs.count == 1, let a = accountIDs.first {
            ForEach(store.folders[a] ?? []) { f in
                Button { store.move(list, to: f) } label: { Label(f.displayName, systemImage: f.role.symbol) }
                    .disabled(list.allSatisfy { $0.folderPath == f.path })
            }
        } else if list.isEmpty {
            Text("Select a message first")
        } else {
            Text("Select messages from one account")
        }
    }
}

struct MoveMenu: View {
    let list: [MessageSummary]
    var body: some View {
        Menu { MoveItems(list: list) } label: { Label("Move to", systemImage: "folder") }
    }
}

struct SnoozeItems: View {
    @EnvironmentObject var store: MailStore
    let list: [MessageSummary]

    static func presets() -> [(String, Date)] {
        let cal = Calendar.current
        let now = Date()
        func at(_ day: Date, _ hour: Int) -> Date { cal.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day }
        var out: [(String, Date)] = []
        out.append(("In 1 Hour", now.addingTimeInterval(3600)))
        let evening = at(now, 18)
        if evening > now.addingTimeInterval(1800) { out.append(("This Evening", evening)) }
        let tomorrow = cal.date(byAdding: .day, value: 1, to: now)!
        out.append(("Tomorrow Morning", at(tomorrow, 8)))
        let weekday = cal.component(.weekday, from: now) // 1 = Sunday
        let daysToSaturday = (7 - weekday + 7) % 7
        if daysToSaturday > 1, let sat = cal.date(byAdding: .day, value: daysToSaturday, to: now) {
            out.append(("This Weekend", at(sat, 9)))
        }
        let daysToMonday = ((2 - weekday) + 7) % 7
        if let mon = cal.date(byAdding: .day, value: daysToMonday == 0 ? 7 : daysToMonday, to: now) {
            out.append(("Next Week", at(mon, 8)))
        }
        return out
    }

    var body: some View {
        ForEach(SnoozeItems.presets(), id: \.0) { p in
            Button("\(p.0) — \(p.1.formatted(.dateTime.weekday(.abbreviated).hour().minute()))") { store.snooze(list, until: p.1) }
        }
        Divider()
        Button("Choose Date & Time…") { SnoozePicker.present(list: list) }
        if list.contains(where: { $0.snoozeUntil != nil }) {
            Divider()
            Button("Unsnooze") { store.unsnooze(list) }
        }
    }
}

struct SnoozeMenu: View {
    let list: [MessageSummary]
    var body: some View {
        Menu { SnoozeItems(list: list) } label: { Label("Snooze / Remind Me", systemImage: "clock") }
    }
}

/// A small floating panel to choose a custom snooze time.
enum SnoozePicker {
    @MainActor
    static func present(list: [MessageSummary]) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 330),
                            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Snooze Until"
        panel.isReleasedWhenClosed = false
        let view = SnoozePickerView(onDone: { date in
            if let date { MailStore.shared.snooze(list, until: date) }
            panel.close()
        })
        panel.contentView = NSHostingView(rootView: view.tint(Preferences.shared.theme.accent))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }
}

private struct SnoozePickerView: View {
    let onDone: (Date?) -> Void
    @ViewState private var date = Calendar.current.date(byAdding: .hour, value: 3, to: Date()) ?? Date()

    var body: some View {
        VStack(spacing: 14) {
            DatePicker("", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                Button("Cancel") { onDone(nil) }
                Spacer()
                Button("Snooze") { onDone(date) }
                    .buttonStyle(GradientButtonStyle(theme: Preferences.shared.theme))
            }
        }
        .padding(18)
        .onExitCommand { onDone(nil) }
    }
}
