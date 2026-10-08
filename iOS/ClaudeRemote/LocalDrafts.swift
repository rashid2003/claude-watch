import Foundation
import WatchProtocol

/// The composer text of each chat on this phone (Application Support), so leaving a chat keeps what was typed.
@MainActor
enum LocalDrafts {
    struct Entry: Codable, Equatable {
        var text: String
        /// When the user last changed it (typing, clearing, sending).
        var at: Date
        /// Set while the text is a desktop draft filled in untouched.
        var prefilled: String?
        var prefilledAt: Date?
    }

    /// Entries older than this are dropped.
    static let maxAge: TimeInterval = 14 * 86400

    private static var url: URL? {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true) else { return nil }
        return dir.appending(path: "drafts.json")
    }

    private static var cache: [String: Entry]?

    private static var all: [String: Entry] {
        get {
            if let cache { return cache }
            let loaded = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? WireCoder.decoder.decode([String: Entry].self, from: $0) } ?? [:]
            let fresh = loaded.filter { Date().timeIntervalSince($0.value.at) < maxAge }
            cache = fresh
            return fresh
        }
        set {
            cache = newValue
            guard let url, let data = try? WireCoder.encoder.encode(newValue) else { return }
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    static func load(_ chatId: String) -> Entry? { all[chatId] }

    static func save(_ chatId: String, _ e: Entry) {
        guard all[chatId] != e else { return }
        all[chatId] = e
    }

    static func clear() {
        cache = [:]
        if let url { try? FileManager.default.removeItem(at: url) }
    }
}
