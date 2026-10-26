import Foundation
import SwiftUI

/// User preferences (non-secret) plus the account list, templates and folder cache.
final class Preferences: ObservableObject {
    static let shared = Preferences()

    @AppStorage("loadRemoteImages") var loadRemoteImages = false
    @AppStorage("blockTrackers") var blockTrackers = true
    @AppStorage("notificationsEnabled") var notificationsEnabled = true
    @AppStorage("markReadOnOpen") var markReadOnOpen = true
    @AppStorage("showPreviewLines") var previewLines = 2
    @AppStorage("autoCheckUpdates") var autoCheckUpdates = true
    @AppStorage("appearance") var appearance = "system"   // system | light | dark
    @AppStorage("density") var density = "comfortable"    // comfortable | compact
    @AppStorage("theme") var themeRaw = "aurora"
    @AppStorage("showHoverActions") var showHoverActions = true
    @AppStorage("trustedSenders") var trustedSendersRaw = ""  // newline-separated, remote images allowed

    var trustedSenders: Set<String> {
        get { Set(trustedSendersRaw.split(separator: "\n").map { $0.lowercased() }) }
        set { trustedSendersRaw = newValue.sorted().joined(separator: "\n") }
    }

    var theme: AppTheme { AppTheme(rawValue: themeRaw) ?? .aurora }

    var colorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    // MARK: JSON files in Application Support

    private static func url(_ name: String) -> URL { AppPaths.support.appendingPathComponent(name) }

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let d = try? Data(contentsOf: url(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(value) else { return }
        let u = url(name)
        try? d.write(to: u, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: u.path)
    }
}
