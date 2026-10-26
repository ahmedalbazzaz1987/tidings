import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var prefs: Preferences

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AccountsSettings().tabItem { Label("Accounts", systemImage: "at") }
            TemplatesSettings().tabItem { Label("Templates", systemImage: "text.badge.plus") }
            PrivacySettings().tabItem { Label("Privacy", systemImage: "hand.raised") }
            AdvancedSettings().tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
            UpdatesSettings().tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
        }
        .frame(width: 660, height: 560)
        .tint(prefs.theme.accent)
        .preferredColorScheme(prefs.colorScheme)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject var prefs: Preferences

    var body: some View {
        Form {
            Section("Theme") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(AppTheme.allCases) { t in
                        Button { prefs.themeRaw = t.rawValue } label: {
                            VStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(t.gradient)
                                    .frame(height: 38)
                                    .overlay {
                                        if prefs.theme == t {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 16, weight: .bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(prefs.theme == t ? Color.primary.opacity(0.5) : Color.clear, lineWidth: 2))
                                Text(t.title).font(.caption.weight(.medium))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
            Picker("Appearance", selection: $prefs.appearance) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .pickerStyle(.segmented)
            Picker("List density", selection: $prefs.density) {
                Text("Comfortable").tag("comfortable")
                Text("Compact").tag("compact")
            }
            .pickerStyle(.segmented)
            Picker("Preview lines", selection: $prefs.previewLines) {
                Text("None").tag(0)
                Text("1 line").tag(1)
                Text("2 lines").tag(2)
                Text("3 lines").tag(3)
            }
            Toggle("Show quick actions when hovering over a message", isOn: $prefs.showHoverActions)
            Toggle("Mark messages as read when opened", isOn: $prefs.markReadOnOpen)
            Toggle("Show notifications for new mail", isOn: $prefs.notificationsEnabled)
                .onChange(of: prefs.notificationsEnabled) { on in if on { Notifier.requestAuthorization() } }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Accounts

private struct AccountsSettings: View {
    @EnvironmentObject var store: MailStore
    @ViewState private var selected: UUID? = nil

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selected) {
                    ForEach(store.accounts) { a in
                        HStack {
                            Circle().fill(a.accentColor).frame(width: 9, height: 9)
                            VStack(alignment: .leading) {
                                Text(a.displayName.isEmpty ? a.email : a.displayName)
                                Text(a.email).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(a.id)
                    }
                    .onMove { store.moveAccounts(from: $0, to: $1) }
                }
                Divider()
                HStack(spacing: 0) {
                    Button { store.showAddAccount = true; NSApp.keyWindow?.close() } label: { Image(systemName: "plus").frame(width: 24, height: 20) }
                    Button {
                        if let id = selected { confirmRemove(id) }
                    } label: { Image(systemName: "minus").frame(width: 24, height: 20) }
                        .disabled(selected == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(4)
            }
            .frame(minWidth: 190, maxWidth: 230)

            Group {
                if let id = selected, let account = store.account(id) {
                    AccountEditor(account: account).id(id)
                } else {
                    Text("Select an account").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 380)
        }
        .onAppear { if selected == nil { selected = store.accounts.first?.id } }
    }

    private func confirmRemove(_ id: UUID) {
        guard let a = store.account(id) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(a.email)?"
        alert.informativeText = "Its password and all downloaded messages will be deleted from this Mac. Nothing is deleted on the server."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            store.removeAccount(id)
            selected = store.accounts.first?.id
        }
    }
}

private struct AccountEditor: View {
    @EnvironmentObject var store: MailStore
    @ViewState var account: Account
    @ViewState private var newPassword = ""
    @ViewState private var status: String? = nil

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Name", text: $account.displayName)
                LabeledContent("Email", value: account.email)
                Picker("Color", selection: $account.colorIndex) {
                    ForEach(0..<Account.palette.count, id: \.self) { i in
                        Label("Color \(i + 1)", systemImage: "circle.fill").foregroundStyle(Account.palette[i]).tag(i)
                    }
                }
                Toggle("Notifications for this account", isOn: $account.notificationsEnabled)
            }
            Section("Signature") {
                TextEditor(text: $account.signature)
                    .font(.system(size: 13))
                    .frame(height: 70)
            }
            Section("Sign-in") {
                if account.authKind == .password {
                    SecureField("New password", text: $newPassword, prompt: Text("Leave empty to keep the current one"))
                } else {
                    Button("Sign In Again…") { Task { await reauthorize() } }
                }
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Servers") {
                TextField("Username", text: $account.username)
                TextField("IMAP server", text: $account.servers.imapHost)
                TextField("IMAP port", value: $account.servers.imapPort, format: .number.grouping(.never))
                Picker("IMAP security", selection: $account.servers.imapSecurity) {
                    ForEach(TransportSecurity.allCases) { Text($0.label).tag($0) }
                }
                TextField("SMTP server", text: $account.servers.smtpHost)
                TextField("SMTP port", value: $account.servers.smtpPort, format: .number.grouping(.never))
                Picker("SMTP security", selection: $account.servers.smtpSecurity) {
                    ForEach(TransportSecurity.allCases) { Text($0.label).tag($0) }
                }
            }
            HStack {
                Spacer()
                Button("Save") { save() }.buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
    }

    private func save() {
        if !newPassword.isEmpty {
            let pw = (account.provider == .gmail || account.provider == .yahoo || account.provider == .icloud) ? AddAccountView.cleanAppPassword(newPassword) : newPassword
            Keychain.setString(pw, for: Keychain.passwordKey(account.id))
            newPassword = ""
        }
        store.updateAccount(account)
        store.refresh(accountID: account.id, includeFolders: true)
        status = "Saved."
    }

    private func reauthorize() async {
        let provider: OAuthProvider = account.authKind == .oauthMicrosoft ? .microsoft : .google
        do {
            let t = try await OAuthFlow.authorize(provider: provider, loginHint: account.email)
            if let d = try? JSONEncoder().encode(t) { Keychain.set(d, for: Keychain.oauthKey(account.id)) }
            store.updateAccount(account)
            // new session picks up the new token
            status = "Signed in."
            store.refresh(accountID: account.id, includeFolders: true)
        } catch {
            status = error.localizedDescription
        }
    }
}

// MARK: - Templates

private struct TemplatesSettings: View {
    @EnvironmentObject var store: MailStore
    @ViewState private var selected: UUID? = nil

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selected) {
                    ForEach(store.templates) { t in Text(t.name).tag(t.id) }
                }
                Divider()
                HStack(spacing: 0) {
                    Button {
                        let t = MailTemplate(name: "New Template", subject: "", body: "")
                        store.templates.append(t)
                        store.saveTemplates()
                        selected = t.id
                    } label: { Image(systemName: "plus").frame(width: 24, height: 20) }
                    Button {
                        store.templates.removeAll { $0.id == selected }
                        store.saveTemplates()
                        selected = store.templates.first?.id
                    } label: { Image(systemName: "minus").frame(width: 24, height: 20) }
                        .disabled(selected == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(4)
            }
            .frame(minWidth: 170, maxWidth: 210)

            if let i = store.templates.firstIndex(where: { $0.id == selected }) {
                Form {
                    TextField("Name", text: $store.templates[i].name)
                    TextField("Subject (optional)", text: $store.templates[i].subject)
                    TextEditor(text: $store.templates[i].body)
                        .font(.system(size: 13))
                        .frame(minHeight: 200)
                    Text("Insert templates from the Templates menu in any new message.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .formStyle(.grouped)
                .onDisappear { store.saveTemplates() }
                .onChange(of: store.templates) { _ in store.saveTemplates() }
                .frame(minWidth: 380)
            } else {
                Text("Select or add a template").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Privacy

private struct PrivacySettings: View {
    @EnvironmentObject var prefs: Preferences
    @ViewState private var cleared = false

    var body: some View {
        Form {
            Section {
                Toggle("Load remote images automatically", isOn: $prefs.loadRemoteImages)
                Text("When off, senders can’t see when or where you opened their email. You can still load images for one message or always trust a sender.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Remove tracking pixels even when images load", isOn: $prefs.blockTrackers)
            }
            Section("Trusted senders") {
                let list = prefs.trustedSenders.sorted()
                if list.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                }
                ForEach(list, id: \.self) { s in
                    HStack {
                        Text(s)
                        Spacer()
                        Button("Remove") {
                            var t = prefs.trustedSenders
                            t.remove(s)
                            prefs.trustedSenders = t
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            Section("Always on") {
                Label("JavaScript in emails is disabled", systemImage: "checkmark.shield")
                Label("Passwords and tokens are kept in the macOS Keychain", systemImage: "checkmark.shield")
                Label("Downloaded message bodies are encrypted (AES-256) on disk", systemImage: "checkmark.shield")
                Label("Encrypted connections only (TLS 1.2+), certificates verified", systemImage: "checkmark.shield")
                Label("No analytics, no cloud, no third-party servers", systemImage: "checkmark.shield")
            }
            Section {
                Button(cleared ? "Cache Cleared" : "Clear Downloaded Messages") {
                    MailDatabase.shared.clearBodies()
                    cleared = true
                }
                .disabled(cleared)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Advanced

private struct AdvancedSettings: View {
    @AppStorage("oauth.microsoft.clientID") private var msClientID = ""
    @AppStorage("oauth.google.clientID") private var googleClientID = ""
    @AppStorage("oauth.google.clientSecret") private var googleSecret = ""

    var body: some View {
        Form {
            Section("Microsoft (Outlook, Hotmail, Live)") {
                TextField("Application (client) ID", text: $msClientID)
                Text("Register a free app at entra.microsoft.com → App registrations → New registration. Choose “Personal Microsoft accounts”, add platform “Mobile and desktop applications” with redirect URI http://localhost, then add the API permissions IMAP.AccessAsUser.All and SMTP.Send (Office 365 Exchange Online).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Google (optional — app passwords also work)") {
                TextField("Client ID", text: $googleClientID)
                SecureField("Client secret", text: $googleSecret)
                Text("console.cloud.google.com → APIs & Services → Credentials → Create OAuth client ID → Desktop app. Add yourself as a test user on the consent screen.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Updates & uninstall

private struct UpdatesSettings: View {
    @EnvironmentObject var updater: Updater
    @EnvironmentObject var prefs: Preferences

    var body: some View {
        Form {
            Section("Updates") {
                LabeledContent("Installed version", value: Updater.currentVersion)
                LabeledContent("Source", value: "github.com/\(Updater.repository)")
                Toggle("Check for updates automatically", isOn: $prefs.autoCheckUpdates)
                HStack {
                    Button("Check Now") { updater.check(userInitiated: true) }
                        .disabled(updater.state.isBusy)
                    Spacer()
                    Text(updater.state.message).font(.callout).foregroundStyle(.secondary)
                }
                if case .available(let v, _, let notes) = updater.state {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Version \(v) is available").font(.headline)
                        if !notes.isEmpty {
                            ScrollView { Text(notes).font(.callout).frame(maxWidth: .infinity, alignment: .leading) }
                                .frame(maxHeight: 90)
                        }
                        Button("Download and Install") { updater.installAvailable() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            Section("Uninstall") {
                Text("Removes Tidings, its settings, caches, downloaded mail and every Keychain item it created. Your email stays on your mail servers.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Uninstall Tidings…", role: .destructive) { Uninstaller.confirmAndRun() }
            }
        }
        .formStyle(.grouped)
    }
}
