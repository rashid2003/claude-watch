import Foundation
import WatchProtocol

/// Where an older page of a transcript ends: the byte offset of a line start, tied to the file (its inode)
/// so a cursor from a replaced file isn't read against the new one. Opaque to the phone: `o:<offset>:<inode>`.
public struct TranscriptCursor: Equatable, Sendable {
    public var offset: UInt64
    public var file: UInt64

    public init(offset: UInt64, file: UInt64) { self.offset = offset; self.file = file }

    public init?(_ s: String) {
        let p = s.split(separator: ":", omittingEmptySubsequences: false)
        guard p.count == 3, p[0] == "o", let o = UInt64(p[1]), let f = UInt64(p[2]) else { return nil }
        offset = o; file = f
    }

    public var string: String { "o:\(offset):\(file)" }
}

/// A transcript's live work as read up to `offset` (a line start), e.g. by `TranscriptScanner`.
public struct WorkSeed: Sendable {
    public var tracker: WorkTracker
    public var offset: UInt64
    public init(tracker: WorkTracker, offset: UInt64) { self.tracker = tracker; self.offset = offset }
}

/// One transcript read from its end: the newest lines are parsed first, older ones only when a page
/// reaches back to them, so opening a long chat costs about one window instead of the whole file.
/// The messages are the same a parse from the start gives (`ChatParser.prepend` carries tool results
/// back across windows). `feed` holds everything loaded and follows what's appended.
/// Not thread-safe: `TranscriptCache` locks around it.
final class TranscriptHistory {
    /// Newest bytes parsed up front, with live work tracked: enough for what's running now.
    static let liveWindow: UInt64 = 4 << 20
    /// Older bytes parsed per step back.
    static let chunk: UInt64 = 1 << 20

    let url: URL
    /// The file's inode when opened.
    let file: UInt64
    /// Messages from `head` to `feed.offset`; `catchUp` reads what's appended.
    let feed: ChatFeed
    /// Where the loaded lines start: a line start, 0 once the whole file is read.
    private(set) var head: UInt64
    private let chunk: UInt64

    /// `workSeed` is asked for the transcript's live work from a full read (the scanner's) when the window
    /// doesn't reach the start of the file, so agents and shells started before it still show.
    init?(url: URL, liveWindow: UInt64 = TranscriptHistory.liveWindow, chunk: UInt64 = TranscriptHistory.chunk,
          workSeed: (() -> WorkSeed?)? = nil) {
        guard let (size, file) = Self.stat(url), let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let end = Self.lineEnd(h, size: size)
        let (start, parser) = autoreleasepool { () -> (UInt64, ChatParser) in
            let (start, data) = Self.readBack(h, end: end, atLeast: liveWindow)
            // A seed read up to inside the window (or past it) covers everything before; one that stops short
            // of the window would leave a gap, so the window alone is used then.
            var seed: WorkSeed?
            if start > 0, let s = workSeed?(), s.offset >= start, s.offset <= size { seed = s }
            return (start, Self.parse(data, at: start, trackWork: true, seed: seed))
        }
        self.url = url
        self.file = file
        self.chunk = max(1, chunk)
        head = start
        feed = ChatFeed(url: url, offset: end, parser: parser)
    }

    var messages: [ChatMessage] { feed.parser.messages }

    /// Reads what was appended. False when the file was replaced or cut short: start over.
    func catchUp() -> Bool {
        guard let (size, f) = Self.stat(url), f == file, size >= feed.offset else { return false }
        _ = feed.poll()
        return true
    }

    /// Up to `limit` messages (whole lines, so a few more when a line holds several) ending before
    /// `cursor`, nil = the newest. The page's `cursor` leads to the one before; nil at the start.
    func page(cursor: TranscriptCursor?, limit: Int) -> MessagesPage {
        if let cursor, cursor.file != file || cursor.offset > feed.offset { return MessagesPage(messages: [], before: nil) }
        let o = cursor?.offset ?? feed.offset
        let limit = max(1, limit)
        load(before: o, limit: limit)
        let starts = feed.parser.lineStarts
        let end = Self.firstIndex(in: starts, atLeast: o)
        var start = max(0, end - limit)
        if start < end { start = Self.firstIndex(in: starts, atLeast: starts[start]) }   // don't split a line
        let next: TranscriptCursor? = start == 0 && head == 0
            ? nil : TranscriptCursor(offset: start < end ? starts[start] : head, file: file)
        return MessagesPage(messages: Array(feed.parser.messages[start..<end]), before: nil, cursor: next?.string)
    }

    /// Reads back to the start of the file (index paging and full opens need every message).
    func loadAll() { load(before: 0, limit: .max) }

    /// Steps back a chunk at a time until `limit` messages come before offset `o`, or the file starts.
    private func load(before o: UInt64, limit: Int) {
        guard head > 0, head > o || Self.firstIndex(in: feed.parser.lineStarts, atLeast: o) < limit,
              let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        while head > 0, head > o || Self.firstIndex(in: feed.parser.lineStarts, atLeast: o) < limit {
            let moved: Bool = autoreleasepool {
                let (start, data) = Self.readBack(h, end: head, atLeast: chunk)
                guard start < head else { return false }
                feed.parser.prepend(Self.parse(data, at: start, trackWork: false))
                head = start
                return true
            }
            if !moved { break }
        }
    }

    // MARK: Reading

    static func stat(_ url: URL) -> (size: UInt64, file: UInt64)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (a[.size] as? NSNumber)?.uint64Value else { return nil }
        return (size, (a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
    }

    /// Just past the last newline at or before `size` (a partial last line is left for later), 0 if none.
    static func lineEnd(_ h: FileHandle, size: UInt64) -> UInt64 {
        var hi = size
        let step: UInt64 = 64 << 10
        while hi > 0 {
            let from = hi > step ? hi - step : 0
            guard (try? h.seek(toOffset: from)) != nil,
                  let got = try? h.read(upToCount: Int(hi - from)), !got.isEmpty else { return 0 }
            if let nl = got.lastIndex(of: 0x0A) { return from + UInt64(nl - got.startIndex) + 1 }
            hi = from
        }
        return 0
    }

    /// The whole lines in about `want` bytes before `end` (a line start): more when a line is longer,
    /// from 0 near the start of the file. Returns where they start and their bytes; (end, empty) on a read error.
    static func readBack(_ h: FileHandle, end: UInt64, atLeast want: UInt64) -> (start: UInt64, data: Data) {
        var lo = end
        var data = Data()
        var step = max(want, 1)
        while lo > 0 {
            let from = lo > step ? lo - step : 0
            guard (try? h.seek(toOffset: from)) != nil,
                  let got = try? h.read(upToCount: Int(lo - from)), got.count == Int(lo - from) else { return (end, Data()) }
            data = data.isEmpty ? got : got + data
            lo = from
            if lo == 0 { break }
            // Bytes up to the first newline belong to a line that starts further back. Earlier reads had
            // no newline but maybe their last byte, so only the new bytes need searching.
            if let nl = got.withUnsafeBytes({ b in b.baseAddress.flatMap { memchr($0, 0x0A, b.count) }.map { b.baseAddress!.distance(to: UnsafeRawPointer($0)) } }),
               nl + 1 < data.count {
                return (lo + UInt64(nl + 1), data.subdata(in: data.startIndex + nl + 1 ..< data.endIndex))
            }
            step *= 2
        }
        return (0, data)
    }

    /// Parses whole lines that start at byte `start`.
    /// With a `seed`, live work starts from its tracker and only lines from its offset on are fed to it.
    static func parse(_ data: Data, at start: UInt64, trackWork: Bool, seed: WorkSeed? = nil) -> ChatParser {
        var p = ChatParser()
        p.trackWork = trackWork
        if let seed {
            p.work = seed.tracker
            p.workFrom = seed.offset
        }
        data.forEachLine { line, at in
            p.lineAt = start + UInt64(at)
            _ = p.consume(line)
        }
        return p
    }

    /// First index whose value is >= `x` in ascending `a` (a.count if none).
    static func firstIndex(in a: [UInt64], atLeast x: UInt64) -> Int {
        var lo = 0, hi = a.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if a[mid] < x { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

/// Transcripts kept between opens, so reopening a chat (or paging back) only reads what was appended
/// or what wasn't read yet. Each is read from its end (`TranscriptHistory`). Least recently used
/// chats are dropped past `capacity`.
public final class TranscriptCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [URL: (history: TranscriptHistory, used: Date)] = [:]
    private let capacity: Int
    private let liveWindow: UInt64
    private let chunk: UInt64
    private let workSeed: ((URL) -> WorkSeed?)?

    /// `workSeed` gives a transcript's live work from a full read (the scanner's), for chats opened from
    /// their end. It's called with the cache locked, so it must not call back into the cache.
    public convenience init(capacity: Int = 16, workSeed: ((URL) -> WorkSeed?)? = nil) {
        self.init(capacity: capacity, liveWindow: TranscriptHistory.liveWindow, chunk: TranscriptHistory.chunk, workSeed: workSeed)
    }

    init(capacity: Int, liveWindow: UInt64, chunk: UInt64, workSeed: ((URL) -> WorkSeed?)? = nil) {
        self.capacity = capacity; self.liveWindow = liveWindow; self.chunk = chunk; self.workSeed = workSeed
    }

    /// The newest `limit` messages (whole lines) with the cursor for older pages, and a feed that
    /// reports what's appended from here on. Reads only the end of the file.
    public func open(_ url: URL, limit: Int) -> (page: MessagesPage, feed: ChatFeed) {
        lock.withLock {
            guard let h = history(url) else { return (MessagesPage(messages: [], before: nil), ChatFeed(url: url)) }
            return (h.page(cursor: nil, limit: limit), h.feed.copy())
        }
    }

    /// The whole chat so far and a feed that reports what's appended from here on. Reads the whole file
    /// once (for phones that page by message index).
    public func open(_ url: URL) -> (messages: [ChatMessage], feed: ChatFeed) {
        lock.withLock {
            guard let h = history(url) else { return ([], ChatFeed(url: url)) }
            h.loadAll()
            return (h.messages, h.feed.copy())
        }
    }

    /// The page before `cursor` (a `MessagesPage.cursor`; nil = the newest). A cursor this file
    /// can't have given (another file, garbage) gets an empty page.
    public func page(_ url: URL, cursor: String?, limit: Int) -> MessagesPage {
        lock.withLock {
            let c = cursor.flatMap(TranscriptCursor.init)
            guard cursor == nil || c != nil, let h = history(url) else { return MessagesPage(messages: [], before: nil) }
            return h.page(cursor: c, limit: limit)
        }
    }

    /// Like `ChatFeed.page`: `before` is an index into the whole chat, so this reads the whole file once.
    public func page(_ url: URL, before: Int?, limit: Int) -> MessagesPage {
        let all: [ChatMessage] = lock.withLock {
            guard let h = history(url) else { return [] }
            h.loadAll()
            return h.messages
        }
        let end = min(before ?? all.count, all.count)
        let start = max(0, end - max(1, limit))
        return MessagesPage(messages: Array(all[start..<end]), before: start > 0 ? start : nil)
    }

    private func history(_ url: URL) -> TranscriptHistory? {
        if let e = entries[url], e.history.catchUp() {
            entries[url]?.used = Date()
            return e.history
        }
        let seed = workSeed.map { f in { f(url) } }
        guard let h = TranscriptHistory(url: url, liveWindow: liveWindow, chunk: chunk, workSeed: seed) else {
            entries[url] = nil
            return nil
        }
        _ = h.catchUp()
        entries[url] = (h, Date())
        if entries.count > capacity, let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key {
            entries[oldest] = nil
        }
        return h
    }
}
