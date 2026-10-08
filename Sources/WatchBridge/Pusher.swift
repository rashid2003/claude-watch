import CryptoKit
import Foundation
import Security
import WatchProtocol

/// An APNs auth key (.p8) plus its ids, kept in the Keychain.
public struct APNsKey: Codable, Sendable, Equatable {
    public var keyId: String
    public var teamId: String
    public var pem: String
    public var topic: String          // the iPhone app's bundle id

    public init(keyId: String, teamId: String, pem: String, topic: String) {
        self.keyId = keyId; self.teamId = teamId; self.pem = pem; self.topic = topic
    }

    static let service = "claude-watch-apns"

    public static func load() -> APNsKey? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: "key", kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(APNsKey.self, from: d)
    }

    @discardableResult
    public func save() -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                   kSecAttrAccount as String: "key"]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = try? JSONEncoder().encode(self)
        add[kSecAttrLabel as String] = "claude-watch APNs key \(keyId)"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public func signingKey() throws -> P256.Signing.PrivateKey { try P256.Signing.PrivateKey(pemRepresentation: pem) }
}

public struct PushNote: Sendable {
    public var category: String       // a PushCategory
    public var title: String
    public var body: String
    public var threadId: String?
    public var collapseId: String?
    public var userInfo: [String: String]

    public init(category: String, title: String, body: String, threadId: String? = nil, collapseId: String? = nil,
                userInfo: [String: String] = [:]) {
        self.category = category; self.title = String(title.prefix(120)); self.body = String(body.prefix(240))
        self.threadId = threadId; self.collapseId = collapseId.map { String($0.prefix(64)) }; self.userInfo = userInfo
    }

    /// A pending prompt. Carries `chatId` and `promptId` so the phone can answer from the notification.
    public static func prompt(_ p: PendingPrompt, account: String) -> PushNote {
        PushNote(category: PushCategory.of(p), title: account + " · " + p.chatTitle,
                 body: p.kind == .question ? p.summary
                     : "\(p.toolName): \(p.summary)" + (p.viewOnly == true ? " · answer in the terminal" : ""),
                 threadId: p.chatId, collapseId: "prompt-" + p.chatId,
                 userInfo: ["chatId": p.chatId, "promptId": p.id, "profileId": p.profileId])
    }

    func payload() -> Data {
        var aps: [String: Any] = ["alert": ["title": title, "body": body], "sound": "default", "category": category]
        if let threadId { aps["thread-id"] = threadId }
        var obj: [String: Any] = ["aps": aps]
        for (k, v) in userInfo { obj[k] = v }
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    }
}

/// Sends alerts straight to Apple's push service with token auth. No server of ours involved.
public final class Pusher: @unchecked Sendable {
    public var key: APNsKey?
    let session: URLSession
    private let lock = NSLock()
    private var cachedJWT: (token: String, at: Date)?
    /// A device's token is no longer valid (410 Unregistered / BadDeviceToken).
    public var onInvalidToken: ((String) -> Void)?
    public internal(set) var lastError: String?

    public init(key: APNsKey?, session: URLSession = .shared) { self.key = key; self.session = session }

    public var isConfigured: Bool { key != nil }

    static func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Provider token, reused for 50 minutes (Apple rejects tokens older than an hour).
    public func jwt(now: Date = Date()) throws -> String {
        try lock.withLock {
            if let c = cachedJWT, now.timeIntervalSince(c.at) < 3000 { return c.token }
            guard let key else { throw WireError("No APNs key") }
            let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": key.keyId], options: [.sortedKeys])
            let claims = try JSONSerialization.data(withJSONObject: ["iss": key.teamId, "iat": Int(now.timeIntervalSince1970)],
                                                    options: [.sortedKeys])
            let input = Self.b64url(header) + "." + Self.b64url(claims)
            let sig = try key.signingKey().signature(for: Data(input.utf8))
            let token = input + "." + Self.b64url(sig.rawRepresentation)
            cachedJWT = (token, now)
            return token
        }
    }

    public func send(_ note: PushNote, to device: Device) {
        guard let key, let token = device.apnsToken, !token.isEmpty else { return }
        let host = device.apnsEnvironment == "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com"
        guard let url = URL(string: "https://\(host)/3/device/\(token)"), let jwt = try? jwt() else {
            lastError = "Couldn't sign the push token; check the APNs key"
            return
        }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        r.setValue(key.topic, forHTTPHeaderField: "apns-topic")
        r.setValue("alert", forHTTPHeaderField: "apns-push-type")
        r.setValue("10", forHTTPHeaderField: "apns-priority")
        if let c = note.collapseId { r.setValue(c, forHTTPHeaderField: "apns-collapse-id") }
        r.httpBody = note.payload()
        session.dataTask(with: r) { [weak self] data, resp, err in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { self?.lastError = nil; return }
            let reason = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }?["reason"] as? String
            self?.lastError = "Push failed: \(reason ?? err?.localizedDescription ?? "HTTP \(status)")"
            if status == 410 || reason == "BadDeviceToken" || reason == "Unregistered" { self?.onInvalidToken?(device.id) }
            if reason == "ExpiredProviderToken" || reason == "InvalidProviderToken" {
                self?.lock.withLock { self?.cachedJWT = nil }
            }
        }.resume()
    }
}
