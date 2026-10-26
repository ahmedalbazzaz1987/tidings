# Tidings

A calm, private, lightweight email app for macOS — native Swift/SwiftUI, no Electron, no cloud, no tracking.

- **Every inbox**: Gmail, iCloud, Outlook/Hotmail, Yahoo, and any IMAP/SMTP mailbox (your own domain / hosting).
- **Unified inbox**, Starred, Snoozed, folders, fast local search + server search, drag-to-folder, swipe actions.
- **Privacy**: remote images and tracking pixels blocked, JavaScript off, strict Content-Security-Policy, links open in your browser.
- **Security**: passwords & tokens in the macOS Keychain, message cache encrypted with AES-256-GCM, TLS 1.2+ with verified certificates only.
- **Push**: new mail arrives instantly via IMAP IDLE, with macOS notifications and a Dock badge.
- **Compose**: rich text (bold, italic, lists, colours, alignment, **right-to-left for Arabic**), attachments (drag & drop), signatures per account, templates, reply/forward with quoting.
- **Phishing shield**: warns when a sender’s name doesn’t match their address, when a domain imitates a known company (paypa1.com, amaz0n-support.com), when a link shows one address but opens another, or when your provider’s SPF/DKIM/DMARC checks fail. Suspicious links ask before opening.
- **Bills radar**: finds bills, statements and autopay emails, pulls out the amount and due date, lists them under *Bills*, and reminds you the day before. All on-device.
- **Snooze / Remind me**: hide a message until later; it comes back with a notification.
- **Updates from GitHub Releases** built in; **clean uninstall** built in.
- Requires macOS 13 Ventura or later.

## Build

Only the Command Line Tools are needed (no Xcode project):

```bash
xcode-select --install      # once, if you don't have them
./build.sh --install        # builds and copies Tidings to /Applications
```

Other options: `./build.sh` (build only → `build/Tidings.app`), `./build.sh --universal`, `./build.sh --release` (universal + zip for GitHub).

Optional, once: `./setup-signing.sh` creates a private signing certificate in your login Keychain so macOS doesn't ask for Keychain access again after each update.

## Adding accounts

| Provider | What to enter |
|---|---|
| Gmail | An **App Password** (Google Account → Security → 2-Step Verification → App passwords). IMAP must be on in Gmail settings. |
| iCloud | An **app-specific password** from account.apple.com → Sign-In and Security. |
| Yahoo | An **app password** from Yahoo Account Security. |
| Your domain / hosting | Mailbox password. Servers default to `mail.<domain>` on 993 (IMAP) / 465 (SMTP) — adjust under *Server settings*. |
| Outlook / Hotmail | Secure browser sign-in (Microsoft no longer accepts passwords for IMAP). Needs a free Client ID — see below. |

### OAuth setup for Outlook / Hotmail (one time, ~3 minutes)

1. Open **entra.microsoft.com** → *App registrations* → *New registration*.
2. Name: `Tidings`. Supported account types: **Personal Microsoft accounts only** (or "any organizational directory and personal accounts" for work mail too).
3. Redirect URI: platform **Public client/native (mobile & desktop)**, value `http://localhost`.
4. After creating: *API permissions* → *Add a permission* → *APIs my organization uses* → **Office 365 Exchange Online** → *Delegated* → tick `IMAP.AccessAsUser.All` and `SMTP.Send`. (Also keep `offline_access`.)
5. *Authentication* → *Allow public client flows* → **Yes**.
6. Copy the **Application (client) ID** into Tidings (Add Account → Outlook, or Settings → Advanced).

Google OAuth is optional (App Passwords are simpler): console.cloud.google.com → Credentials → *OAuth client ID* → *Desktop app*, add yourself as a test user, paste the Client ID and secret in Settings → Advanced.

## Updating

Tidings checks `github.com/ahmedalbazzaz1987/tidings` releases on launch (toggle in Settings → Updates). To publish a version:

```bash
./release.sh 1.0.1 "What changed"     # needs: brew install gh && gh auth login
```

or run `./build.sh --release` and upload `build/Tidings-<version>.zip` to a new GitHub release tagged `v<version>` by hand. The app downloads the zip, checks it is really Tidings and its signature is intact, swaps itself and restarts.

## Uninstalling

**Settings → Updates → Uninstall Tidings…** or run `./uninstall.sh`. Either removes:

- the app itself
- `~/Library/Application Support/Tidings` (accounts list, encrypted cache)
- `~/Library/Caches/com.ahmedalbazzaz.tidings`, preferences, saved window state, WebKit/HTTP storage
- every Keychain item with service `com.ahmedalbazzaz.tidings`

Your email stays on your mail servers. (macOS itself keeps the notification permission entry in System Settings → Notifications until you remove it there.)

## Where things live

```
Sources/Core      socket (TLS/STARTTLS), models
Sources/Mail      IMAP parser & client, SMTP, MIME parse/build, OAuth (PKCE)
Sources/Storage   SQLite cache, Keychain, preferences
Sources/Sync      per-account sync + IDLE, app state
Sources/UI        SwiftUI windows and views
Sources/System    updater and uninstaller
```
