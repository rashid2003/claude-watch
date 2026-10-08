import Foundation

/// Turns a Claude Code transcript (.jsonl) into chat messages for the iPhone app:
/// your prompts, Claude's text, one line per tool call (✓/✗ once its result arrives) and API errors.
/// Thinking, sidechains (subagents), meta entries and bookkeeping lines are left out.
/// Alongside, it follows what the chat is doing (`work`), including its subagents' transcripts.
public final class ChatFeed {
    public let url: URL
    private var offset: UInt64 = 0
    private var parser = ChatParser()
    private var subagents: SubagentFeeds

    public init(url: URL) {
        self.url = url
        subagents = SubagentFeeds(transcript: url)
    }

    /// New or updated messages since the last call (the first call returns the whole chat).
    /// A tool message is returned again, with the same id, when its result arrives.
    /// A partial last line is left for the next call.
    public func poll() -> [ChatMessage] {
        defer { subagents.poll(&parser.work) }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else { return [] }
        if size.uint64Value < offset { offset = 0; parser = ChatParser(); subagents = SubagentFeeds(transcript: url) }   // rewritten
        guard size.uint64Value > offset, let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        try? h.seek(toOffset: offset)
        let data = (try? h.readToEnd()) ?? Data()
        guard let lastNL = data.lastIndex(of: 0x0A) else { return [] }
        var touched: [Int] = []
        var seen = Set<Int>()
        for line in data[..<lastNL].split(separator: 0x0A) {
            for i in parser.consume(Data(line)) where seen.insert(i).inserted { touched.append(i) }
        }
        offset += UInt64(lastNL - data.startIndex + 1)
        return touched.sorted().map { parser.messages[$0] }
    }

    /// Every message parsed so far.
    public var all: [ChatMessage] { parser.messages }

    /// What the chat is doing, as of the last poll.
    public var work: LiveWork { parser.work.live() }
    public var workTracker: WorkTracker { parser.work }

    /// A feed that carries on from where this one is, without re-reading the file.
    public func copy() -> ChatFeed {
        let f = ChatFeed(url: url)
        f.offset = offset
        f.parser = parser
        f.subagents = subagents
        return f
    }

    public static func messages(fromLines lines: [Data]) -> [ChatMessage] {
        var p = ChatParser()
        for l in lines { _ = p.consume(l) }
        return p.messages
    }

    /// Up to `limit` messages ending just before index `before` (nil = the end of the chat).
    /// `before` in the result is the cursor for the previous page, nil at the start.
    public static func page(url: URL, before: Int?, limit: Int) -> MessagesPage {
        let data = (try? Data(contentsOf: url)) ?? Data()
        let all = messages(fromLines: data.split(separator: 0x0A).map { Data($0) })
        let end = min(before ?? all.count, all.count)
        let start = max(0, end - max(1, limit))
        return MessagesPage(messages: Array(all[start..<end]), before: start > 0 ? start : nil)
    }

    /// "Ran swift build", "Edited App.swift", "github · create issue", ...
    public static func oneLiner(tool: String, input: [String: Any]) -> String {
        func s(_ k: String) -> String? { (input[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func file(_ k: String) -> String { s(k).map { ($0 as NSString).lastPathComponent } ?? "a file" }
        func clip(_ t: String, _ n: Int = 80) -> String {
            let one = t.split(whereSeparator: \.isNewline).first.map(String.init) ?? t
            return one.count > n ? String(one.prefix(n)) + "…" : one
        }
        switch tool {
        case "Bash": return "Ran " + clip(s("command") ?? "a command")
        case "Edit", "MultiEdit", "NotebookEdit": return "Edited " + file(s("file_path") != nil ? "file_path" : "notebook_path")
        case "Write": return "Wrote " + file("file_path")
        case "Read": return "Read " + file("file_path")
        case "Grep": return "Searched “\(clip(s("pattern") ?? "", 60))”"
        case "Glob": return "Listed " + clip(s("pattern") ?? "files", 60)
        case "WebFetch": return "Fetched " + (s("url").flatMap { URL(string: $0)?.host } ?? "a page")
        case "WebSearch": return "Searched the web: " + clip(s("query") ?? "", 60)
        case "Agent", "Task": return "Agent: " + clip(s("description") ?? s("prompt") ?? "subtask", 60)
        case "TodoWrite", "TaskCreate", "TaskUpdate": return "Updated tasks"
        case "Skill": return "Skill: " + (s("skill") ?? s("command") ?? "")
        case "AskUserQuestion": return "Asked you a question"
        case "ExitPlanMode": return "Proposed a plan"
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.dropFirst(5).components(separatedBy: "__")
                if parts.count >= 2 { return parts[0] + " · " + parts[1].replacingOccurrences(of: "_", with: " ") }
            }
            return tool
        }
    }
}

/// Incremental transcript → message state. `consume` returns indices of added / changed messages.
struct ChatParser {
    var messages: [ChatMessage] = []
    var work = WorkTracker()
    private var toolIndex: [String: Int] = [:]   // tool_use id -> message index

    mutating func consume(_ line: Data) -> [Int] {
        guard line.count > 20 else { return [] }
        let head = line.prefix(2048)
        let isUser = head.range(of: Data("\"type\":\"user\"".utf8)) != nil
        let isAssistant = head.range(of: Data("\"type\":\"assistant\"".utf8)) != nil
        if !isUser && !isAssistant && WorkTracker.isWorkAttachment(head) {
            if let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { work.consume(obj) }
            return []
        }
        guard isUser || isAssistant || line.count > 2048 else { return [] }

        if line.count > 262_144 {
            // Huge tool results: only the id and error flag matter.
            return rawToolResult(line)
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = obj["type"] as? String, type == "user" || type == "assistant" else { return [] }
        work.consume(obj)
        if obj["isSidechain"] as? Bool == true || obj["isMeta"] as? Bool == true { return [] }
        let uuid = obj["uuid"] as? String ?? UUID().uuidString
        let at = (obj["timestamp"] as? String).flatMap(TranscriptScanner.parseISO) ?? Date()
        let msg = obj["message"] as? [String: Any] ?? [:]

        if type == "assistant", obj["isApiErrorMessage"] as? Bool == true {
            let text = ((msg["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n"))
                .flatMap { $0.isEmpty ? nil : $0 } ?? (obj["error"] as? String ?? "API error")
            return [append(ChatMessage(id: uuid, kind: .error, at: at, text: text))]
        }

        if let text = msg["content"] as? String {
            guard type == "user", let t = Self.userText(text) else { return [] }
            return [append(ChatMessage(id: uuid, kind: .user, at: at, text: t))]
        }
        var out: [Int] = []
        for (n, block) in ((msg["content"] as? [[String: Any]]) ?? []).enumerated() {
            let id = uuid + ":" + String(n)
            switch block["type"] as? String {
            case "text":
                guard let raw = block["text"] as? String else { continue }
                if type == "user" {
                    if let t = Self.userText(raw) { out.append(append(ChatMessage(id: id, kind: .user, at: at, text: t))) }
                } else if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out.append(append(ChatMessage(id: id, kind: .assistant, at: at, text: raw)))
                }
            case "tool_use" where type == "assistant":
                let name = block["name"] as? String ?? "Tool"
                let useId = block["id"] as? String
                let m = ChatMessage(id: id, kind: .tool, at: at,
                                    text: ChatFeed.oneLiner(tool: name, input: block["input"] as? [String: Any] ?? [:]),
                                    toolName: name, toolUseId: useId)
                let i = append(m)
                if let useId { toolIndex[useId] = i }
                out.append(i)
            case "tool_result" where type == "user":
                if let useId = block["tool_use_id"] as? String, let i = resolve(useId, ok: block["is_error"] as? Bool != true) {
                    out.append(i)
                }
            default: continue
            }
        }
        return out
    }

    private mutating func append(_ m: ChatMessage) -> Int {
        messages.append(m)
        return messages.count - 1
    }

    private mutating func resolve(_ useId: String, ok: Bool) -> Int? {
        guard let i = toolIndex.removeValue(forKey: useId) else { return nil }
        messages[i].toolOK = ok
        return i
    }

    private mutating func rawToolResult(_ line: Data) -> [Int] {
        guard let id = TranscriptScanner.toolUseId(inRaw: line) else { return [] }
        let isError = line.range(of: Data("\"is_error\":true".utf8)) != nil
        work.result(id: id, isError: isError, at: TranscriptScanner.timestamp(inRaw: line) ?? Date())
        return resolve(id, ok: !isError).map { [$0] } ?? []
    }

    /// What to show for a user text entry; nil for injected context.
    static func userText(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.hasPrefix("<system-reminder>") || t.hasPrefix("<local-command-")
            || t.hasPrefix("[Request interrupted") || t.hasPrefix("<task-notification>") { return nil }
        if t.hasPrefix("<command-name>"), let end = t.range(of: "</command-name>") {
            let cmd = t[t.index(t.startIndex, offsetBy: 14)..<end.lowerBound]
            let args = t.range(of: "<command-args>").flatMap { a in
                t.range(of: "</command-args>").map { String(t[a.upperBound..<$0.lowerBound]) } } ?? ""
            return (String(cmd) + (args.isEmpty ? "" : " " + args))
        }
        return t
    }
}

/// Parsed transcripts kept between opens, so reopening a chat (or paging back) only reads what was
/// appended since. Least recently used chats are dropped past `capacity`.
public final class TranscriptCache: @unchecked Sendable {
    private let lock = NSLock()
    private var feeds: [URL: (feed: ChatFeed, used: Date)] = [:]
    private let capacity: Int

    public init(capacity: Int = 16) { self.capacity = capacity }

    /// The whole chat so far, and a feed that reports what's appended from here on.
    public func open(_ url: URL) -> (messages: [ChatMessage], feed: ChatFeed) {
        lock.withLock {
            let f = caughtUp(url)
            return (f.all, f.copy())
        }
    }

    /// Like `ChatFeed.page`, from the cache.
    public func page(_ url: URL, before: Int?, limit: Int) -> MessagesPage {
        let all = lock.withLock { caughtUp(url).all }
        let end = min(before ?? all.count, all.count)
        let start = max(0, end - max(1, limit))
        return MessagesPage(messages: Array(all[start..<end]), before: start > 0 ? start : nil)
    }

    private func caughtUp(_ url: URL) -> ChatFeed {
        let f = feeds[url]?.feed ?? ChatFeed(url: url)
        _ = f.poll()
        feeds[url] = (f, Date())
        if feeds.count > capacity, let oldest = feeds.min(by: { $0.value.used < $1.value.used })?.key {
            feeds[oldest] = nil
        }
        return f
    }
}
