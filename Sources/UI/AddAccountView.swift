import SwiftUI
import AppKit

struct AddAccountView: View {
    @EnvironmentObject var store: MailStore
    @Environment(\.dismiss) private var dismiss

    @ViewState private var provider: MailProvider? = nil
    @ViewState private var name = NSFullUserName()
    @ViewState private var email = ""
    @ViewState private var password = ""
    @ViewState private var username = ""
    @ViewState private var servers = MailProvider.custom.defaults(for: "")
    @ViewState private var showServers = false
    @ViewState private var useGoogleOAuth = false
    @ViewState private var working = false
    @ViewState private var error: String? = nil
    @ViewState private var clientID = ""
    @ViewState private var clientSecret = ""

    var body: some View {
        VStack(spacing: 0) {
            if let provider {
                details(provider)
            } else {
                picker
            }
        }
        .frame(width: 560)
        .frame(minHeight: 460)
        .onExitCommand { dismiss() }
    }

    // MARK: Step 1

    private var picker: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Add an Account").font(.title2.weight(.semibold))
                Spacer()
                if !store.accounts.isEmpty {
                    Button("Cancel") { dismiss() }
                }
            }
            Text("Choose your email provider.").foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(MailProvider.allCases) { p in
                    Button { select(p) } label: { ProviderCard(provider: p) }
                        .buttonStyle(.plain)
                }
            }
            Spacer()
            Label("Your password is stored only in the macOS Keychain on this Mac.", systemImage: "lock.shield")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }

    private func select(_ p: MailProvider) {
        provider = p
        servers = p.defaults(for: email)
        showServers = p == .custom
        clientID = OAuthProvider.microsoft.clientID
        if p == .gmail {
            clientID = OAuthProvider.google.clientID
            clientSecret = OAuthProvider.google.clientSecret
        }
    }

    // MARK: Step 2

    private func details(_ p: MailProvider) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Button { provider = nil; error = nil } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                Image(systemName: p.symbol).foregroundStyle(p.tint).font(.title2)
                Text(p.title).font(.title2.weight(.semibold))
                Spacer()
            }

            Form {
                TextField("Your name", text: $name, prompt: Text("Shown to people you email"))
                TextField("Email address", text: $email, prompt: Text("you@example.com"))
                    .onChange(of: email) { v in
                        if username.isEmpty || username == String(v.dropLast()) { username = v }
                        if p == .custom { servers = p.defaults(for: v) }
                    }

                if p == .outlook {
                    oauthSection(provider: "Microsoft")
                } else {
                    if !(p == .gmail && useGoogleOAuth) {
                        SecureField(p == .custom ? "Password" : "App password", text: $password)
                        Text(p.appPasswordHelp).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if p == .gmail {
                        Toggle("Sign in with Google instead (advanced)", isOn: $useGoogleOAuth)
                        if useGoogleOAuth { oauthSection(provider: "Google") }
                    }
                }

                DisclosureGroup("Server settings", isExpanded: $showServers) {
                    TextField("Username", text: $username)
                    HStack {
                        TextField("Incoming (IMAP)", text: $servers.imapHost)
                        TextField("Port", value: $servers.imapPort, format: .number.grouping(.never)).frame(width: 70)
                        Picker("", selection: $servers.imapSecurity) {
                            ForEach(TransportSecurity.allCases) { Text($0.label).tag($0) }
                        }.labelsHidden().frame(width: 110)
                    }
                    HStack {
                        TextField("Outgoing (SMTP)", text: $servers.smtpHost)
                        TextField("Port", value: $servers.smtpPort, format: .number.grouping(.never)).frame(width: 70)
                        Picker("", selection: $servers.smtpSecurity) {
                            ForEach(TransportSecurity.allCases) { Text($0.label).tag($0) }
                        }.labelsHidden().frame(width: 110)
                    }
                    if p == .custom {
                        Text("Hosting providers usually use mail.yourdomain.com with ports 993 (IMAP) and 465 (SMTP). Check your cPanel → Email Accounts → Connect Devices page.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .onSubmit { if canSubmit(p) { Task { await submit(p) } } }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if working { ProgressView().controlSize(.small); Text("Connecting securely…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }
                Button(isOAuth(p) ? "Sign In…" : "Add Account") { Task { await submit(p) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit(p))
            }
        }
        .padding(24)
    }

    private func canSubmit(_ p: MailProvider) -> Bool {
        !working && MailAddress.isValidEmail(email) && (isOAuth(p) || !password.isEmpty)
    }

    private func isOAuth(_ p: MailProvider) -> Bool { p == .outlook || (p == .gmail && useGoogleOAuth) }

    @ViewBuilder
    private func oauthSection(provider name: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(name) requires secure sign-in in your browser. Tidings needs a free Client ID that you register once (about 3 minutes — see “OAuth setup” in the README).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("\(name) Client ID", text: $clientID, prompt: Text("xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"))
            if name == "Google" {
                SecureField("Google Client secret", text: $clientSecret)
            }
        }
    }

    // MARK: Submit

    private func submit(_ p: MailProvider) async {
        error = nil
        working = true
        defer { working = false }
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
        var account = Account(provider: p,
                              displayName: name.trimmingCharacters(in: .whitespaces),
                              email: trimmedEmail,
                              username: username.isEmpty ? trimmedEmail : username.trimmingCharacters(in: .whitespaces),
                              authKind: .password,
                              servers: servers)
        if store.accounts.contains(where: { $0.email.lowercased() == trimmedEmail.lowercased() }) {
            error = "This account is already added."
            return
        }
        do {
            if isOAuth(p) {
                let oauth: OAuthProvider = p == .outlook ? .microsoft : .google
                UserDefaults.standard.set(clientID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "oauth.\(oauth.id).clientID")
                if p == .gmail {
                    UserDefaults.standard.set(clientSecret.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "oauth.\(oauth.id).clientSecret")
                }
                account.authKind = p == .outlook ? .oauthMicrosoft : .oauthGoogle
                let tokens = try await OAuthFlow.authorize(provider: oauth, loginHint: trimmedEmail)
                NSApp.activate(ignoringOtherApps: true)
                try await AccountSession.verify(account: account, auth: .oauth(user: account.username, accessToken: tokens.accessToken))
                if let d = try? JSONEncoder().encode(tokens) { Keychain.set(d, for: Keychain.oauthKey(account.id)) }
            } else {
                // App passwords are often shown with spaces (Google) — they are not part of the password.
                let pw = (p == .gmail || p == .yahoo || p == .icloud) ? AddAccountView.cleanAppPassword(password) : password
                try await AccountSession.verify(account: account, auth: .password(user: account.username, password: pw))
                Keychain.setString(pw, for: Keychain.passwordKey(account.id))
            }
            store.addAccount(account)
            dismiss()
        } catch {
            self.error = friendly(error, provider: p)
        }
    }

    /// App passwords are shown in groups ("abcd efgh ijkl mnop"); copying them can bring
    /// ordinary or non-breaking spaces and invisible characters along. None belong to the password.
    static func cleanAppPassword(_ s: String) -> String {
        String(s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0)
            && !CharacterSet.controlCharacters.contains($0)
            && !["\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}"].contains($0) }
            .map(Character.init))
    }

    private func friendly(_ error: Error, provider p: MailProvider) -> String {
        let msg = error.localizedDescription
        if case MailError.authenticationFailed(let server) = error {
            let detail = server.isEmpty ? "" : "\n\nServer said: \(server)"
            switch p {
            case .gmail: return "Google rejected the sign-in. Use a 16-letter App Password (not your normal password) and make sure 2-Step Verification is on." + detail
            case .icloud: return "iCloud rejected the sign-in. Use an app-specific password from account.apple.com." + detail
            case .yahoo: return "Yahoo rejected the sign-in. Generate an app password in Yahoo Account Security." + detail
            default: return msg
            }
        }
        if (error as NSError).domain == NSURLErrorDomain {
            return "Couldn’t reach the server. Check the server name, port and your internet connection. (\(msg))"
        }
        return msg
    }
}

private struct ProviderCard: View {
    let provider: MailProvider
    @ViewState private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(provider.tint.gradient)
                Image(systemName: provider.symbol).foregroundStyle(.white).font(.system(size: 16, weight: .semibold))
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.title).font(.headline)
                Text(provider.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(height: 72)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(hover ? 0.08 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(hover ? provider.tint.opacity(0.6) : Color.primary.opacity(0.08)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}
