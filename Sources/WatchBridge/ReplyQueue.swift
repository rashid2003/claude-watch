import Foundation
import WatchProtocol

/// Replies the phone sent while their chat was busy, kept on disk until the chat goes idle and they are sent.
public final class ReplyQueue: @unchecked Sendable {
    private let url: URL?
    private let lock = NSLock()
    private var items: [QueuedReply]

    /// `url` nil keeps the queue in memory only (tests).
    public init(url: URL?) {
        self.url = url
        items = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? WireCoder.decoder.decode([QueuedReply].self, from: $0) } ?? []
    }

    public var all: [QueuedReply] { lock.withLock { items } }

    public func has(chatId: String) -> Bool { lock.withLock { items.contains { $0.chatId == chatId && $0.error == nil } } }

    /// Chats with replies still to send (failed ones wait for the user).
    public var waitingChats: Set<String> { lock.withLock { Set(items.filter { $0.error == nil }.map(\.chatId)) } }

    @discardableResult
    public func add(chatId: String, text: String) -> QueuedReply {
        let r = QueuedReply(chatId: chatId, text: text)
        mutate { $0.append(r) }
        return r
    }

    /// Removes one reply. False when it was already sent or removed.
    public func remove(id: String) -> Bool {
        var found = false
        mutate { list in
            found = list.contains { $0.id == id }
            list.removeAll { $0.id == id }
        }
        return found
    }

    /// Takes every reply still to send for a chat, oldest first.
    public func take(chatId: String) -> [QueuedReply] {
        var taken: [QueuedReply] = []
        mutate { list in
            taken = list.filter { $0.chatId == chatId && $0.error == nil }
            list.removeAll { $0.chatId == chatId && $0.error == nil }
        }
        return taken
    }

    /// Puts replies that couldn't be sent back, marked with why, so the phone can show them.
    public func fail(_ replies: [QueuedReply], error: String) {
        mutate { list in list.insert(contentsOf: replies.map { var r = $0; r.error = error; return r }, at: 0) }
    }

    /// The text sent for several queued replies at once.
    public static func combined(_ replies: [QueuedReply]) -> String {
        replies.map(\.text).joined(separator: "\n\n")
    }

    /// Changes the list and writes it, under the lock so writes land in order.
    private func mutate(_ f: (inout [QueuedReply]) -> Void) {
        lock.withLock {
            f(&items)
            guard let url, let data = try? WireCoder.encoder.encode(items) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}
