import ActivityKit
import Foundation
import WatchProtocol

/// The Lock Screen / Dynamic Island activity that tracks every account's limits.
/// The name is part of the push-to-start contract with the Mac (`ActivityPush.attributesType`).
struct LimitsActivityAttributes: ActivityAttributes {
    typealias ContentState = LiveLimits
    var macName: String
}

/// What the app hands the widgets through the shared app group: the latest limits, and enough of the pairing
/// for a widget to ask the Mac itself when the app hasn't run for a while.
enum WidgetShare {
    static let group = "group.dev.lajward.SessionWatch"
    static let kind = "limits"

    private static let limitsKey = "widget.limits"
    private static let macKey = "widget.macName"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: group) }

    struct Cached: Codable {
        var limits: LiveLimits
        var macName: String
        var fetchedAt: Date
    }

    static func save(_ limits: LiveLimits, macName: String, at: Date = Date()) {
        guard let d = try? JSONEncoder().encode(Cached(limits: limits, macName: macName, fetchedAt: at)) else { return }
        defaults?.set(d, forKey: limitsKey)
    }

    static func load() -> Cached? {
        defaults?.data(forKey: limitsKey).flatMap { try? JSONDecoder().decode(Cached.self, from: $0) }
    }

    static func clear() {
        defaults?.removeObject(forKey: limitsKey)
        Link.clear()
    }

    /// The Mac's addresses and this phone's bearer token, in a Keychain item the widget extension can read.
    struct Link: Codable, Equatable {
        var baseURLs: [URL]
        var token: String
        var macName: String

        private static var query: [String: Any] {
            [kSecClass as String: kSecClassGenericPassword,
             kSecAttrService as String: "dev.lajward.SessionWatch.widget",
             kSecAttrAccount as String: "link",
             kSecAttrAccessGroup as String: WidgetShare.group]
        }

        static func load() -> Link? {
            var q = query
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
            return try? JSONDecoder().decode(Link.self, from: d)
        }

        func save() {
            guard Self.load() != self, let data = try? JSONEncoder().encode(self) else { return }
            SecItemDelete(Self.query as CFDictionary)
            var add = Self.query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }

        static func clear() { SecItemDelete(query as CFDictionary) }

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
