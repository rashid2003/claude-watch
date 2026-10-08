import ActivityKit
import Foundation
import WatchProtocol

/// The Lock Screen / Dynamic Island activity that tracks every account's limits.
/// The name is part of the push-to-start contract with the Mac (`ActivityPush.attributesType`).
struct LimitsActivityAttributes: ActivityAttributes {
    typealias ContentState = LiveLimits
    var macName: String
}

/// What the app hands the widgets through a shared Keychain group (no app group needed): the latest limits, and
/// enough of the pairing for a widget to ask the Mac itself when the app hasn't run for a while.
enum WidgetShare {
    /// `<team>.<app id>.shared`, from Info.plist so Session Watch Next (`dev.lajward.SessionWatch.next`) has its own.
    static let group = Bundle.main.object(forInfoDictionaryKey: "SWKeychainShareGroup") as? String
        ?? "6W5NJUTUCV.dev.lajward.SessionWatch.shared"
    static let kind = "limits"

    struct Cached: Codable {
        var limits: LiveLimits
        var macName: String
        var fetchedAt: Date
    }

    static func save(_ limits: LiveLimits, macName: String, at: Date = Date()) {
        guard let d = try? JSONEncoder().encode(Cached(limits: limits, macName: macName, fetchedAt: at)) else { return }
        Item.write(d, account: "limits")
    }

    static func load() -> Cached? {
        Item.read(account: "limits").flatMap { try? JSONDecoder().decode(Cached.self, from: $0) }
    }

    static func clear() {
        Item.delete(account: "limits")
        Link.clear()
    }

    /// One generic-password item in the shared group, readable after the first unlock (widgets run while locked).
    enum Item {
        private static func query(_ account: String) -> [String: Any] {
            [kSecClass as String: kSecClassGenericPassword,
             kSecAttrService as String: "dev.lajward.SessionWatch.widget",
             kSecAttrAccount as String: account,
             kSecAttrAccessGroup as String: WidgetShare.group]
        }

        static func read(account: String) -> Data? {
            var q = query(account)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
            return out as? Data
        }

        static func write(_ data: Data, account: String) {
            let q = query(account)
            let attrs: [String: Any] = [kSecValueData as String: data]
            if SecItemUpdate(q as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
                var add = q
                add[kSecValueData as String] = data
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                SecItemAdd(add as CFDictionary, nil)
            }
        }

        static func delete(account: String) { SecItemDelete(query(account) as CFDictionary) }
    }

    /// The Mac's addresses and this phone's bearer token, in a Keychain item the widget extension can read.
    struct Link: Codable, Equatable {
        var baseURLs: [URL]
        var token: String
        var macName: String

        static func load() -> Link? {
            Item.read(account: "link").flatMap { try? JSONDecoder().decode(Link.self, from: $0) }
        }

        func save() {
            guard Self.load() != self, let data = try? JSONEncoder().encode(self) else { return }
            Item.write(data, account: "link")
        }

        static func clear() { Item.delete(account: "link") }

        /// Asks the Mac for a fresh snapshot, trying each address in turn. Nil when none answers.
        func fetch() async -> LiveLimits? {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 6
            cfg.timeoutIntervalForResource = 15
            let session = URLSession(configuration: cfg)
            for base in baseURLs {
                var req = URLRequest(url: base.appending(path: "v1/snapshot"))
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                guard let (data, resp) = try? await session.data(for: req),
                      (resp as? HTTPURLResponse)?.statusCode == 200,
                      let snap = try? WireCoder.decoder.decode(Snapshot.self, from: data) else { continue }
                return LiveLimits(snap)
            }
            return nil
        }
    }
}
