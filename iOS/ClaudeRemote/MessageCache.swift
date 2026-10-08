import Foundation
import WatchProtocol

/// Recent transcripts on disk (Caches), so a chat opens at once with what was there last time while the
/// Mac sends the fresh copy. Keeps the newest messages of the most recently opened chats.
enum MessageCache {
    struct Entry: Codable {
        var savedAt: Date
        var messages: [ChatMessage]
        /// Paging cursor that went with `messages`: an index (older Macs) or `cursor`.
        var before: Int?
        var cursor: String?

        var older: OlderCursor? { OlderCursor(cursor: cursor, before: before) }
    }

    static let keepMessages = 300
    static let keepChats = 40

    private static var dir: URL? {
        guard let base = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true) else { return nil }
        let d = base.appending(path: "transcripts", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static func file(_ chatId: String) -> URL? {
        let safe = chatId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? chatId
        return dir?.appending(path: safe + ".json")
    }

    static func load(_ chatId: String) -> Entry? {
        guard let url = file(chatId), let data = try? Data(contentsOf: url) else { return nil }
        return try? WireCoder.decoder.decode(Entry.self, from: data)
    }

    static func save(_ chatId: String, messages: [ChatMessage], older: OlderCursor?) {
        guard let url = file(chatId), !messages.isEmpty else { return }
        let dropped = max(0, messages.count - keepMessages)
        var before: Int?, cursor: String?
        switch older {
        case .index(let i): before = i
        case .token(let c): cursor = c
        case nil: break
        }
        if dropped > 0 {
            // Trimming the front moves an index along with it. A Mac cursor can't be moved: it's dropped, and
            // the chat gets a fresh one from the Mac when it's opened.
            before = (before ?? 0) + dropped
            if cursor != nil { before = nil; cursor = nil }
        }
        let entry = Entry(savedAt: Date(), messages: Array(messages.suffix(keepMessages)), before: before, cursor: cursor)
        guard let data = try? WireCoder.encoder.encode(entry) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        prune()
    }

    static func clear() {
        guard let d = dir else { return }
        try? FileManager.default.removeItem(at: d)
    }

    /// Drops the least recently saved chats past `keepChats`.
    private static func prune() {
        guard let d = dir,
              let files = try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > keepChats else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(keepChats) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
