import Foundation
import Security

/// What pairing leaves on the phone: where the Mac is and the bearer token it handed out.
struct Credentials: Codable, Equatable, Sendable {
    /// Candidate base URLs in the order they should be tried (the last one that worked first).
    var baseURLs: [URL]
    var token: String
    var deviceId: String
    var macName: String
}

/// The pairing record, stored as JSON in one generic-password item. Readable after the first unlock
/// so notification actions work while the phone is locked; never synced or backed up to other devices.
enum Keychain {
    private static let service = "dev.lajward.ClaudeRemote"
    private static let account = "pairing"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> Credentials? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    @discardableResult
    static func save(_ c: Credentials) -> Bool {
        guard let data = try? JSONEncoder().encode(c) else { return false }
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = query
        add.merge(attrs) { $1 }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
