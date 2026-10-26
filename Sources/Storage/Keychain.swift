import Foundation
import Security

/// Stores secrets (passwords, OAuth tokens, the cache encryption key) in the macOS Keychain.
/// Nothing secret is ever written to disk in plain form.
enum Keychain {
    static let service = "com.ahmedalbazzaz.tidings"

    private static func baseQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    @discardableResult
    static func set(_ data: Data, for key: String) -> Bool {
        let query = baseQuery(key)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecAttrLabel as String] = "Tidings"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func data(for key: String) -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func setString(_ s: String, for key: String) { set(Data(s.utf8), for: key) }
    static func string(for key: String) -> String? { data(for: key).map { String(decoding: $0, as: UTF8.self) } }

    static func delete(_ key: String) {
        SecItemDelete(baseQuery(key) as CFDictionary)
    }

    /// Removes every item Tidings ever created (used by the uninstaller).
    static func deleteAll() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service]
        for _ in 0..<200 {
            if SecItemDelete(query as CFDictionary) != errSecSuccess { break }
        }
    }

    // Convenience keys
    static func passwordKey(_ id: UUID) -> String { "password.\(id.uuidString)" }
    static func oauthKey(_ id: UUID) -> String { "oauth.\(id.uuidString)" }
    static let cacheKeyName = "cache-key"
}
