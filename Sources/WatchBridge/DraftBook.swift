import Foundation
import WatchProtocol

/// Each chat's unsent text, from the phone (posted) or the Claude desktop composer (read on the Mac).
/// The newest change wins; kept on disk so phone drafts survive a restart.
public final class DraftBook: @unchecked Sendable {
    private let url: URL?
    private let lock = NSLock()
    private var drafts: [String: ChatDraft]
    /// Desktop composer text as last read per chat, so only changes count.
    private var seenDesktop: [String: String] = [:]
    /// Drafts older than this are dropped when loading.
    static let maxAge: TimeInterval = 14 * 86400

    /// `url` nil keeps drafts in memory only (tests).
    public init(url: URL?, now: Date = Date()) {
        self.url = url
        let saved = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? WireCoder.decoder.decode([String: ChatDraft].self, from: $0) } ?? [:]
        drafts = saved.filter { now.timeIntervalSince($0.value.at) < Self.maxAge }
    }

    public var all: [String: ChatDraft] { lock.withLock { drafts } }

    public func draft(chatId: String) -> ChatDraft? { lock.withLock { drafts[chatId] } }

    /// The phone's composer text. Empty clears the phone's draft but leaves a desktop one.
    /// Returns whether anything changed.
    @discardableResult
    public func setPhone(chatId: String, text: String, at: Date = Date()) -> Bool {
        let text = String(text.prefix(DraftMerge.maxLength))
        return mutate { d in
            let cur = d[chatId]
            if DraftMerge.isBlank(text) {
                guard cur?.source == .phone else { return false }
                d[chatId] = nil
                return true
            }
            if cur?.text == text { return false }   // e.g. the phone prefilled the desktop's text
            d[chatId] = ChatDraft(text: text, source: .phone, at: at)
            return true
        }
    }

    /// The desktop composer's text as just read. Only changes since the last read count; the first read
    /// of a chat doesn't replace a phone draft (its text may be older than it).
    @discardableResult
    public func observeDesktop(chatId: String, text: String, at: Date = Date()) -> Bool {
        let text = String(text.prefix(DraftMerge.maxLength))
        return mutate { d in
            let before = seenDesktop[chatId]
            seenDesktop[chatId] = text
            guard before != text else { return false }
            let cur = d[chatId]
            if DraftMerge.isBlank(text) {
                guard cur?.source == .desktop else { return false }
                d[chatId] = nil
                return true
            }
            if before == nil, cur?.source == .phone { return false }
            if cur?.text == text { return false }
            d[chatId] = ChatDraft(text: text, source: .desktop, at: at)
            return true
        }
    }

    /// A reply went out: the draft is spent. The desktop composer's current text stays "seen",
    /// so it only comes back if it changes.
    @discardableResult
    public func clear(chatId: String) -> Bool {
        mutate { d in d.removeValue(forKey: chatId) != nil }
    }

    /// Forgets desktop reads for chats no longer watched, so watching one again starts fresh.
    public func forgetDesktop(except keep: Set<String>) {
        lock.withLock { seenDesktop = seenDesktop.filter { keep.contains($0.key) } }
    }

    /// Changes the drafts and writes them when something changed, under the lock so writes land in order.
    private func mutate(_ f: (inout [String: ChatDraft]) -> Bool) -> Bool {
        lock.withLock {
            guard f(&drafts) else { return false }
            guard let url, let data = try? WireCoder.encoder.encode(drafts) else { return true }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        }
    }
}
