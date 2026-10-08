import Foundation

/// Token counts for one API response. `weighted` approximates how usage limits
/// charge: cache reads are cheap, output is expensive.
public struct TokenCount: Codable, Hashable, Sendable {
    public var raw: Double = 0
    public var weighted: Double = 0

    public init(raw: Double = 0, weighted: Double = 0) { self.raw = raw; self.weighted = weighted }

    public init(usage u: [String: Any]) {
        func n(_ k: String) -> Double { (u[k] as? NSNumber)?.doubleValue ?? 0 }
        let input = n("input_tokens"), output = n("output_tokens")
        let write = n("cache_creation_input_tokens"), read = n("cache_read_input_tokens")
        raw = input + output + write + read
        weighted = input + 1.25 * write + 0.1 * read + 5 * output
    }

    static func + (a: TokenCount, b: TokenCount) -> TokenCount { .init(raw: a.raw + b.raw, weighted: a.weighted + b.weighted) }
    static func - (a: TokenCount, b: TokenCount) -> TokenCount { .init(raw: a.raw - b.raw, weighted: a.weighted - b.weighted) }
}

/// Per-session token usage in 5-minute buckets.
public struct TokenBuckets: Codable, Sendable {
    public static let width: TimeInterval = 300
    public var b: [Int: TokenCount] = [:]

    public init() {}

    mutating func add(_ c: TokenCount, at date: Date) {
        let k = Int(date.timeIntervalSince1970 / Self.width)
        b[k, default: TokenCount()] = b[k, default: TokenCount()] + c
    }

    public func sum(from: Date, to: Date = .distantFuture) -> TokenCount {
        let lo = Int(from.timeIntervalSince1970 / Self.width)
        let hi = to == .distantFuture ? Int.max : Int(to.timeIntervalSince1970 / Self.width)
        var total = TokenCount()
        for (k, v) in b where k >= lo && k <= hi { total = total + v }
        return total
    }

    mutating func prune(before date: Date) {
        let lo = Int(date.timeIntervalSince1970 / Self.width)
        b = b.filter { $0.key >= lo }
    }
}

struct FileScanState: Codable {
    var offset: UInt64 = 0
    var mtime: Date = .distantPast
    var isMain: Bool = true
    var tail = TranscriptTail()
    var lastMsgId: String?
    var lastMsgCount = TokenCount()
    var lastMsgAt: Date?
    /// Main transcripts only: running tools, subagents, background tasks.
    var work: WorkTracker?
}

struct ScanCache: Codable {
    var version = 3   // 3: FileScanState.work (live work), so old caches rescan once
    var files: [String: FileScanState] = [:]
    var buckets: [String: TokenBuckets] = [:]   // keyed by desktop session id
}

/// Incrementally reads Claude Code transcripts (~/.claude/projects/**.jsonl).
public final class TranscriptScanner {
    public static let retention: TimeInterval = 7 * 86400 + 6 * 3600
    private var cache: ScanCache
    private var locator: [String: [URL]] = [:]  // cliSessionId -> files (main first)
    private var locatorBuiltAt: Date = .distantPast
    private var dirty = false
    private var lastSave: Date = .distantPast
    private let cacheURL: URL
    /// Every CLI config dir's `projects/` (the default one first). Changing it rebuilds the locator.
    public var projectsDirs: [URL] {
        didSet { if projectsDirs != oldValue { locatorBuiltAt = .distantPast } }
    }

    public init(cacheURL: URL = Paths.scanCache, projectsDir: URL = Paths.projects) {
        self.cacheURL = cacheURL
        self.projectsDirs = [projectsDir]
        if let data = try? Data(contentsOf: cacheURL),
           let c = try? JSONCoder.decoder.decode(ScanCache.self, from: data), c.version == 3 {
            cache = c
        } else {
            cache = ScanCache()
        }
    }

    public func tail(for session: SessionInfo) -> TranscriptTail {
        guard let id = session.cliSessionId, let main = transcriptURL(cliSessionId: id) else { return TranscriptTail() }
        return cache.files[main.path]?.tail ?? TranscriptTail()
    }

    func tail(forCli id: String?) -> TranscriptTail {
        guard let id, let main = transcriptURL(cliSessionId: id) else { return TranscriptTail() }
        return cache.files[main.path]?.tail ?? TranscriptTail()
    }

    /// What the session's transcript says is running (running items only), nil when nothing is.
    public func work(for session: SessionInfo, now: Date = Date()) -> LiveWork? {
        guard let id = session.cliSessionId, let main = transcriptURL(cliSessionId: id) else { return nil }
        return cache.files[main.path]?.work?.live(now: now).brief
    }

    /// The live work kept for a transcript (main transcripts only) and the offset it was read up to.
    func workSeed(for url: URL) -> WorkSeed? {
        guard let st = cache.files[url.path], let w = st.work else { return nil }
        return WorkSeed(tracker: w, offset: st.offset)
    }

    public func buckets(for sessionId: String) -> TokenBuckets { cache.buckets[sessionId] ?? TokenBuckets() }

    public func transcriptURL(cliSessionId: String) -> URL? {
        locator[cliSessionId]?.first { $0.lastPathComponent == cliSessionId + ".jsonl" }
    }

    /// Brings every file belonging to `sessions` up to date. Returns true if anything changed.
    @discardableResult
    public func scan(sessions: [SessionInfo], now: Date = Date()) -> Bool {
        if now.timeIntervalSince(locatorBuiltAt) > 60 || sessions.contains(where: { s in
            s.cliSessionId.map { locator[$0] == nil && s.lastActivityAt > locatorBuiltAt } ?? false
        }) {
            rebuildLocator()
            locatorBuiltAt = now
        }
        let horizon = now.addingTimeInterval(-Self.retention)
        var changed = false
        var live = Set<String>()
        for s in sessions where s.lastActivityAt > horizon {
            var ids = s.priorCliSessionIds
            if let id = s.cliSessionId { ids.append(id) }
            for id in ids {
                for url in locator[id] ?? [] {
                    live.insert(url.path)
                    if scanFile(url, sessionId: s.id, isMain: id == s.cliSessionId && url.lastPathComponent == id + ".jsonl", horizon: horizon) {
                        changed = true
                    }
                }
            }
        }
        // Drop states for files no longer referenced; prune old buckets.
        if cache.files.count > live.count {
            for k in cache.files.keys where !live.contains(k) {
                if let st = cache.files[k], st.mtime < horizon { cache.files[k] = nil; dirty = true }
            }
        }
        if changed {
            for k in cache.buckets.keys { cache.buckets[k]?.prune(before: horizon) }
            cache.buckets = cache.buckets.filter { !$0.value.b.isEmpty }
        }
        if dirty && now.timeIntervalSince(lastSave) > 60 { save(); lastSave = now }
        return changed
    }

    public func save() {
        guard dirty, let data = try? JSONCoder.encoder.encode(cache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
        dirty = false
    }

    private func rebuildLocator() {
        locator = Self.locate(projectsDirs)
    }

    /// cliSessionId -> files (main first). A session held by more than one config dir (a copied chat)
    /// takes all its files from the dir with the newest main transcript (the earlier dir on a tie),
    /// the same rule `CLIConfigDir.merge` picks its terminal chat by.
    static func locate(_ projectsDirs: [URL]) -> [String: [URL]] {
        let fm = FileManager.default
        var map: [String: [URL]] = [:]
        for projects in projectsDirs {
            var own: [String: [URL]] = [:]
            for dir in (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
                for entry in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                    if entry.hasSuffix(".jsonl") {
                        let id = String(entry.dropLast(6))
                        own[id, default: []].insert(dir.appendingPathComponent(entry), at: 0)
                    } else if entry.count == 36 {
                        let sub = dir.appendingPathComponent(entry).appendingPathComponent("subagents")
                        for f in (try? fm.contentsOfDirectory(atPath: sub.path)) ?? [] where f.hasSuffix(".jsonl") {
                            own[entry, default: []].append(sub.appendingPathComponent(f))
                        }
                    }
                }
            }
            if map.isEmpty { map = own; continue }
            for (id, files) in own {
                if let old = map[id], mainMtime(old, id) >= mainMtime(files, id) { continue }
                map[id] = files
            }
        }
        return map
    }

    private static func mainMtime(_ files: [URL], _ id: String) -> Date {
        guard let main = files.first(where: { $0.lastPathComponent == id + ".jsonl" }) else { return .distantPast }
        return (try? FileManager.default.attributesOfItem(atPath: main.path)[.modificationDate] as? Date) ?? .distantPast
    }

    private func scanFile(_ url: URL, sessionId: String, isMain: Bool, horizon: Date) -> Bool {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return false }
        let mtime = attrs[.modificationDate] as? Date ?? .distantPast
        var st = cache.files[url.path] ?? FileScanState()
        st.isMain = isMain
        if st.offset > size { st = FileScanState(); st.isMain = isMain }  // truncated / rewritten
        if st.offset == size { return false }
        if mtime < horizon && st.offset == 0 { return false }             // untouched old file

        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        try? h.seek(toOffset: st.offset)
        var buckets = cache.buckets[sessionId] ?? TokenBuckets()
        var pending = Data()
        let chunk = 4 << 20
        var more = true
        while more {
            // Each chunk in its own pool: FileHandle/JSON objects are autoreleased.
            autoreleasepool {
                let data = (try? h.read(upToCount: chunk)) ?? Data()
                if data.isEmpty { more = false; return }
                pending.append(data)
                var start = pending.startIndex
                while let nl = pending[start...].firstIndex(of: 0x0A) {
                    let line = pending[start..<nl]
                    processLine(line, state: &st, buckets: &buckets, horizon: horizon)
                    st.offset += UInt64(nl - start + 1)
                    start = pending.index(after: nl)
                }
                pending = Data(pending[start...])
            }
        }
        st.mtime = mtime
        cache.files[url.path] = st
        cache.buckets[sessionId] = buckets
        dirty = true
        return true
    }

    func processLine(_ line: Data, state st: inout FileScanState, buckets: inout TokenBuckets, horizon: Date) {
        guard line.count > 20 else { return }
        // Cheap pre-filter: only user/assistant entries matter.
        let head = line.prefix(4096)
        let isAssistant = head.range(of: Data("\"type\":\"assistant\"".utf8)) != nil
            || (line.count < 65536 && line.range(of: Data("\"type\":\"assistant\"".utf8)) != nil)
        let isUser = !isAssistant && (head.range(of: Data("\"type\":\"user\"".utf8)) != nil
            || (line.count < 65536 && line.range(of: Data("\"type\":\"user\"".utf8)) != nil))
        guard isAssistant || isUser else {
            if st.isMain, WorkTracker.isWorkAttachment(head),
               let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                if st.work == nil { st.work = WorkTracker() }
                st.work?.consume(obj)
            }
            return
        }

        if isUser && line.count > 262_144 {
            // Huge tool results: skip full parse, classify cheaply.
            guard st.isMain else { return }
            st.tail.last = line.fastRange(of: Data("\"tool_result\"".utf8)) != nil ? .toolResult : .userPrompt
            if let ts = Self.timestamp(inRaw: line) { st.tail.lastAt = ts }
            if let id = Self.toolUseId(inRaw: line) {
                st.work?.result(id: id, isError: line.fastRange(of: Data("\"is_error\":true".utf8)) != nil, at: st.tail.lastAt ?? Date())
            }
            return
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        let type = obj["type"] as? String
        guard type == "assistant" || type == "user" else { return }
        let at = (obj["timestamp"] as? String).flatMap(Self.parseISO) ?? Date()
        let sidechain = obj["isSidechain"] as? Bool ?? false

        if st.isMain, !sidechain {
            if st.work == nil { st.work = WorkTracker() }
            st.work?.consume(obj)
        }
        if type == "user" {
            if obj["isMeta"] as? Bool == true || !st.isMain || sidechain { return }
            let msg = obj["message"] as? [String: Any]
            var kind: TranscriptTail.Last = .userPrompt
            if let content = msg?["content"] as? [[String: Any]],
               content.contains(where: { $0["type"] as? String == "tool_result" }) { kind = .toolResult }
            st.tail.last = kind
            st.tail.lastAt = at
            return
        }

        let msg = obj["message"] as? [String: Any] ?? [:]
        if at > horizon, let usage = msg["usage"] as? [String: Any], (msg["model"] as? String) != "<synthetic>" {
            let count = TokenCount(usage: usage)
            let id = msg["id"] as? String
            if let id, id == st.lastMsgId, let prevAt = st.lastMsgAt {
                // Same response streamed across lines: replace its earlier contribution.
                buckets.add(count - st.lastMsgCount, at: prevAt)
            } else {
                buckets.add(count, at: at)
                st.lastMsgAt = at
            }
            st.lastMsgId = id
            st.lastMsgCount = count
        }
        guard st.isMain, !sidechain else { return }

        if obj["isApiErrorMessage"] as? Bool == true {
            let err = obj["error"] as? String
            if err == "rate_limit" {
                let q = obj["quotaLimits"] as? [String: Any]
                let resets = (q?["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                let text = ((msg["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "Usage limit reached"
                st.tail.lastRateLimit = RateLimitHit(at: at, resetsAt: resets,
                                                     kind: LimitKind(apiValue: q?["rateLimitType"] as? String), text: text)
                st.tail.last = .rateLimited
            } else {
                st.tail.last = .apiError
            }
            st.tail.lastAt = at
            return
        }
        switch msg["stop_reason"] as? String {
        case "end_turn", "stop_sequence", "max_tokens", "refusal": st.tail.last = .assistantDone
        default: st.tail.last = .assistantTool
        }
        st.tail.lastAt = at
        st.tail.lastSuccessAt = at
    }

    static func toolUseId(inRaw line: Data) -> String? {
        guard let r = line.fastRange(of: Data("\"tool_use_id\":\"".utf8)) else { return nil }
        let rest = line[r.upperBound...].prefix(80)
        guard let end = rest.firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        return String(decoding: rest[..<end], as: UTF8.self)
    }

    static func timestamp(inRaw line: Data) -> Date? {
        guard let r = line.fastRange(of: Data("\"timestamp\":\"".utf8)) else { return nil }
        let bytes = line[r.upperBound...].prefix(40)
        guard let end = bytes.firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        return parseISO(String(decoding: bytes[..<end], as: UTF8.self))
    }

    /// Parses "2026-09-28T20:57:55.123Z" without a formatter (hot path).
    static func parseISO(_ s: String) -> Date? {
        let u = Array(s.utf8)
        guard u.count >= 20, u[4] == 45, u[7] == 45, u[10] == 84 else { return nil }
        func num(_ a: Int, _ n: Int) -> Int32 {
            var v: Int32 = 0
            for i in a..<(a + n) { v = v * 10 + Int32(u[i] &- 48) }
            return v
        }
        var t = tm()
        t.tm_year = num(0, 4) - 1900
        t.tm_mon = num(5, 2) - 1
        t.tm_mday = num(8, 2)
        t.tm_hour = num(11, 2)
        t.tm_min = num(14, 2)
        t.tm_sec = num(17, 2)
        var frac = 0.0
        if u.count > 20, u[19] == 46 {
            var i = 20, scale = 0.1
            while i < u.count, u[i] >= 48, u[i] <= 57 { frac += Double(u[i] - 48) * scale; scale /= 10; i += 1 }
        }
        return Date(timeIntervalSince1970: Double(timegm(&t)) + frac)
    }
}

extension Data {
    /// Calls `body` with each non-empty newline-separated line (a copy) and its offset from `startIndex`,
    /// like `split(separator: 0x0A)` but with memchr: splitting byte by byte dominated reading big transcripts.
    func forEachLine(_ body: (Data, Int) -> Void) {
        withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            var start = 0
            while start < buf.count {
                let rest = buf.count - start
                let nl = memchr(base + start, 0x0A, rest).map { base.distance(to: UnsafeRawPointer($0)) } ?? buf.count
                if nl > start { body(Data(bytes: base + start, count: nl - start), start) }
                start = nl + 1
            }
        }
    }

    /// `range(of:)` through memmem: far faster on huge lines (tool results of several MB scanned whole).
    func fastRange(of needle: Data) -> Range<Index>? {
        guard !needle.isEmpty, count >= needle.count else { return nil }
        return withUnsafeBytes { hay -> Range<Index>? in
            needle.withUnsafeBytes { n -> Range<Index>? in
                guard let base = hay.baseAddress, let p = memmem(base, hay.count, n.baseAddress, n.count) else { return nil }
                let off = base.distance(to: UnsafeRawPointer(p))
                return (startIndex + off)..<(startIndex + off + needle.count)
            }
        }
    }
}
