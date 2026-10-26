import SwiftUI
import AppKit
import UserNotifications

@main
struct TidingsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // Plain references, NOT @StateObject. With @StateObject every change in the
    // store (each mail check) re-evaluated this body and rebuilt all menus — the
    // pattern that made Harbor 1.1.0 freeze on macOS 27. Views observe these
    // objects through environmentObject instead.
    private let store = MailStore.shared
    private let prefs = Preferences.shared
    private let updater = Updater.shared
    private let radar = BillRadar.shared

    var body: some Scene {
        WindowGroup("Tidings", id: "main") {
            MainView()
                .environmentObject(store)
                .environmentObject(prefs)
                .environmentObject(updater)
                .environmentObject(radar)
                .frame(minWidth: 980, minHeight: 600)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            // No .keyboardShortcut here on purpose (see note above). Shortcuts are
            // handled by ShortcutMonitor in the app delegate; the menu titles show them.
            CommandGroup(replacing: .newItem) {
                Button("New Message    ⌘N") { ComposeWindow.open(.new) }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updater.shared.check(userInitiated: true) }
            }
            CommandMenu("Message") {
                Button("Reply    ⌘R") { Shortcuts.perform(.reply) }
                Button("Reply All    ⇧⌘R") { Shortcuts.perform(.replyAll) }
                Button("Forward    ⇧⌘F") { Shortcuts.perform(.forward) }
                Divider()
                Button("Archive    ⌃⌘A") { Shortcuts.perform(.archive) }
                Button("Move to Trash    ⌘⌫") { Shortcuts.perform(.delete) }
                Button("Mark as Read / Unread    ⇧⌘U") { Shortcuts.perform(.toggleRead) }
                Button("Star / Unstar    ⇧⌘L") { Shortcuts.perform(.toggleStar) }
                Button("Move to Junk    ⇧⌘J") { Shortcuts.perform(.junk) }
                Divider()
                Button("Get New Mail    ⇧⌘N") { Shortcuts.perform(.getMail) }
            }
            TextFormattingCommands()
        }

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(prefs)
                .environmentObject(updater)
        }
    }
}

/// Keyboard shortcuts, handled with an NSEvent monitor instead of SwiftUI's
/// .keyboardShortcut (which crashed on macOS 27 when menus were rebuilt).
@MainActor
enum Shortcuts {
    enum Action { case newMessage, reply, replyAll, forward, archive, delete, toggleRead, toggleStar, junk, getMail, send }

    static func perform(_ action: Action) {
        let store = MailStore.shared
        let sel = store.selectedMessages
        switch action {
        case .newMessage: ComposeWindow.open(.new)
        case .reply: if let m = sel.first { ComposeWindow.open(.reply(m, all: false)) }
        case .replyAll: if let m = sel.first { ComposeWindow.open(.reply(m, all: true)) }
        case .forward: if let m = sel.first { ComposeWindow.open(.forward(m)) }
        case .archive: store.archive(sel)
        case .delete: store.delete(sel)
        case .toggleRead: store.toggleRead(sel)
        case .toggleStar: store.toggleFlag(sel)
        case .junk: store.markJunk(sel)
        case .getMail: store.refreshAll()
        case .send: ComposeWindow.sendFromKeyWindow()
        }
    }

    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let action = action(for: event) else { return event }
            perform(action)
            return nil
        }
    }

    private static func action(for event: NSEvent) -> Action? {
        let mods = event.modifierFlags.intersection([.command, .shift, .control, .option])
        guard mods.contains(.command) else { return nil }
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()
        let window = event.window
        let id = window?.identifier?.rawValue ?? ""
        let inCompose = id == "tidings.compose"
        let editingText = window?.firstResponder is NSText

        // ⌘↩ sends from a compose window.
        if inCompose {
            if mods == [.command] && (event.keyCode == 36 || event.keyCode == 76) { return .send }
            return nil
        }
        // Everything else belongs to the main window (not Settings, sheets or panels).
        if id.contains("Settings") || window?.attachedSheet != nil || window is NSPanel { return nil }

        let cmd: NSEvent.ModifierFlags = [.command]
        let cmdShift: NSEvent.ModifierFlags = [.command, .shift]
        let cmdCtrl: NSEvent.ModifierFlags = [.command, .control]
        if mods == cmd {
            if key == "n" { return .newMessage }
            if key == "r" { return .reply }
        } else if mods == cmdShift {
            switch key {
            case "r": return .replyAll
            case "f": return .forward
            case "u": return .toggleRead
            case "l": return .toggleStar
            case "j": return .junk
            case "n": return .getMail
            default: break
            }
        } else if mods == cmdCtrl, key == "a" {
            return .archive
        }
        // ⌘⌫ deletes messages, but not while typing (where it deletes a line).
        if mods == [.command], event.keyCode == 51, !editingText { return .delete }
        return nil
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        Shortcuts.install()
        Task { @MainActor in
            MailStore.shared.start()
            if Preferences.shared.autoCheckUpdates {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                Updater.shared.check(userInitiated: false)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MailStore.shared.shutdown()
    }

    /// mailto: links (when Tidings is chosen as the default email app).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "mailto" {
            ComposeWindow.open(.mailto(url))
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { for w in sender.windows where w.identifier?.rawValue.contains("main") ?? false { w.makeKeyAndOrderFront(nil) } }
        return true
    }

    // Show banners even while Tidings is in front.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.identifier
        Task { @MainActor in
            do {
                NSApp.activate(ignoringOtherApps: true)
                let store = MailStore.shared
                if id.hasPrefix("bill-") {
                    store.selection = .bills
                    store.selectedIDs = [String(id.dropFirst(5))]
                } else if store.messages.contains(where: { $0.id == id }) {
                    store.selectedIDs = [id]
                }
            }
        }
        completionHandler()
    }
}
