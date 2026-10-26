import Foundation
import AppKit

/// Checks GitHub Releases for a newer version and installs it in place.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    /// github.com/<owner>/<repo> that hosts the releases.
    static let repository = "ahmedalbazzaz1987/tidings"

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, url: URL, notes: String)
        case downloading
        case failed(String)

        var isBusy: Bool { self == .checking || self == .downloading }

        var message: String {
            switch self {
            case .idle: return ""
            case .checking: return "Checking…"
            case .upToDate: return "Tidings is up to date."
            case .available(let v, _, _): return "Version \(v) available."
            case .downloading: return "Downloading…"
            case .failed(let s): return s
            }
        }
    }

    @Published private(set) var state: State = .idle

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    func check(userInitiated: Bool) {
        guard !state.isBusy else { return }
        state = .checking
        Task {
            do {
                var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Updater.repository)/releases/latest")!)
                req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                req.setValue("Tidings/\(Updater.currentVersion)", forHTTPHeaderField: "User-Agent")
                req.cachePolicy = .reloadIgnoringLocalCacheData
                let (data, response) = try await URLSession.shared.data(for: req)
                if (response as? HTTPURLResponse)?.statusCode == 404 {
                    state = .failed("No releases published yet.")
                    return
                }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    state = .failed("Couldn’t read the release information.")
                    return
                }
                let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                let assets = json["assets"] as? [[String: Any]] ?? []
                let zip = assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".zip") == true }
                let urlString = zip?["browser_download_url"] as? String
                if Updater.isNewer(version, than: Updater.currentVersion), let urlString, let url = URL(string: urlString) {
                    let notes = (json["body"] as? String) ?? ""
                    state = .available(version: version, url: url, notes: notes)
                    if !userInitiated { promptInstall(version: version, notes: notes) }
                } else {
                    state = .upToDate
                }
            } catch {
                state = userInitiated ? .failed("Couldn’t check for updates: \(error.localizedDescription)") : .idle
            }
            if userInitiated, case .upToDate = state {
                let a = NSAlert()
                a.messageText = "You’re up to date"
                a.informativeText = "Tidings \(Updater.currentVersion) is the latest version."
                a.runModal()
            } else if userInitiated, case .available(let v, _, let notes) = state {
                promptInstall(version: v, notes: notes)
            }
        }
    }

    private func promptInstall(version: String, notes: String) {
        let a = NSAlert()
        a.messageText = "Tidings \(version) is available"
        a.informativeText = "You have \(Updater.currentVersion). Install the update now? Tidings will restart.\n\n" + String(notes.prefix(600))
        a.addButton(withTitle: "Install and Restart")
        a.addButton(withTitle: "Later")
        if a.runModal() == .alertFirstButtonReturn { installAvailable() }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    func installAvailable() {
        guard case .available(_, let url, _) = state else { return }
        guard let host = url.host?.lowercased(), url.scheme == "https",
              host == "github.com" || host.hasSuffix(".githubusercontent.com") else {
            state = .failed("Refusing to download from an unexpected address.")
            return
        }
        state = .downloading
        Task {
            do {
                let (tmp, _) = try await URLSession.shared.download(from: url)
                let work = AppPaths.caches.appendingPathComponent("Update-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let zipURL = work.appendingPathComponent("Tidings.zip")
                try FileManager.default.moveItem(at: tmp, to: zipURL)
                try Updater.run("/usr/bin/ditto", ["-x", "-k", zipURL.path, work.path])
                guard let newApp = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
                        .first(where: { $0.pathExtension == "app" }) else {
                    throw MailError.server("The download did not contain an app.")
                }
                // Make sure this really is Tidings before replacing anything.
                let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist"))
                guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
                    throw MailError.server("The downloaded app is not Tidings.")
                }
                try? Updater.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
                try Updater.run("/usr/bin/codesign", ["--verify", "--deep", newApp.path])
                try replaceAndRelaunch(with: newApp, cleanup: work)
            } catch {
                state = .failed("Update failed: \(error.localizedDescription)")
            }
        }
    }

    /// A tiny script waits for Tidings to quit, swaps the bundle and relaunches it.
    private func replaceAndRelaunch(with newApp: URL, cleanup: URL) throws {
        let current = Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(current.path).old"
        mv "\(current.path)" "\(current.path).old" && mv "\(newApp.path)" "\(current.path)" && rm -rf "\(current.path).old"
        rm -rf "\(cleanup.path)"
        open "\(current.path)"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try p.run()
        NSApp.terminate(nil)
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if p.terminationStatus != 0 { throw MailError.server("\((tool as NSString).lastPathComponent) failed: \(out)") }
        return out
    }
}

/// Removes Tidings and everything it created.
@MainActor
enum Uninstaller {
    static func confirmAndRun() {
        let a = NSAlert()
        a.alertStyle = .critical
        a.messageText = "Uninstall Tidings?"
        a.informativeText = "This removes the app, all accounts, saved passwords, settings, caches and downloaded messages from this Mac. Your email on the servers is not touched. This cannot be undone."
        a.addButton(withTitle: "Uninstall")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        run()
    }

    static func run() {
        MailStore.shared.shutdown()
        MailDatabase.shared.close()
        Keychain.deleteAll()
        NSApp.dockTile.badgeLabel = nil

        let pid = ProcessInfo.processInfo.processIdentifier
        let app = Bundle.main.bundleURL.path
        let leftovers = AppPaths.allLeftovers.map { "rm -rf \"\($0.path)\"" }.joined(separator: "\n")
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        defaults delete \(AppPaths.bundleID) >/dev/null 2>&1
        \(leftovers)
        rm -rf "$(getconf DARWIN_USER_CACHE_DIR)\(AppPaths.bundleID)" "$(getconf DARWIN_USER_TEMP_DIR)\(AppPaths.bundleID)" 2>/dev/null
        rm -rf "\(app)"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try? p.run()
        NSApp.terminate(nil)
    }
}
