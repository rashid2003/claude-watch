import Foundation

/// A tool call in the main transcript that has no result yet.
public struct OpenToolUse: Sendable, Hashable {
    public var id: String
    public var name: String
    public var fields: [String: String]   // top-level string inputs (+ "question" for AskUserQuestion)
    public var at: Date
    public init(id: String, name: String, fields: [String: String], at: Date) {
        self.id = id; self.name = name; self.fields = fields; self.at = at
    }
}

/// Works out whether a desktop chat is waiting on you. The desktop app keeps its permission prompts
/// in memory only, so this looks at what it leaves behind: a tool call with no result, a transcript
/// that has gone quiet, and no process started for the tool.
public enum PromptDetector {
    static let quiet: TimeInterval = 4

    /// The oldest unanswered tool call of the current turn, from the last 256 KB of the transcript.
    public static func openToolUse(url: URL) -> OpenToolUse? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let window: UInt64 = 256 * 1024
        try? h.seek(toOffset: size > window ? size - window : 0)
        var data = (try? h.readToEnd()) ?? Data()
        if size > window, let nl = data.firstIndex(of: 0x0A) { data = data[data.index(after: nl)...] }

        var open: [(OpenToolUse)] = []
        for raw in data.split(separator: 0x0A) {
            let line = Data(raw)
            guard line.count < 262_144 || line.range(of: Data("\"tool_result\"".utf8)) != nil else { continue }
            if line.count >= 262_144 {
                // Huge results: drop the matching use without a full parse.
                open.removeAll { line.range(of: Data("\"tool_use_id\":\"\($0.id)\"".utf8)) != nil }
                continue
            }
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let type = obj["type"] as? String, type == "user" || type == "assistant",
                  obj["isSidechain"] as? Bool != true, obj["isMeta"] as? Bool != true else { continue }
            let msg = obj["message"] as? [String: Any] ?? [:]
            let at = (obj["timestamp"] as? String).flatMap(TranscriptScanner.parseISO) ?? Date()
            if obj["isApiErrorMessage"] as? Bool == true { open.removeAll(); continue }
            if msg["content"] is String { if type == "user" { open.removeAll() }; continue }
            for block in (msg["content"] as? [[String: Any]]) ?? [] {
                switch block["type"] as? String {
                case "tool_use" where type == "assistant":
                    guard let id = block["id"] as? String else { continue }
                    let input = block["input"] as? [String: Any] ?? [:]
                    var fields = input.compactMapValues { $0 as? String }
                    if let q = (input["questions"] as? [[String: Any]])?.first?["question"] as? String { fields["question"] = q }
                    open.append(OpenToolUse(id: id, name: block["name"] as? String ?? "Tool", fields: fields, at: at))
                case "tool_result" where type == "user":
                    let id = block["tool_use_id"] as? String
                    open.removeAll { $0.id == id }
                case "text" where type == "user":
                    open.removeAll()   // a new prompt
                default: continue
                }
            }
        }
        return open.first
    }

    /// Whether an unanswered tool call is waiting on the user rather than still running.
    /// `childStarts` are the start times of the chat's CLI process's children.
    public static func isWaiting(_ t: OpenToolUse, transcriptMtime: Date, childStarts: [Date], now: Date) -> Bool {
        let age = now.timeIntervalSince(t.at)
        if t.name == "AskUserQuestion" || t.name == "ExitPlanMode" { return true }
        guard now.timeIntervalSince(transcriptMtime) >= quiet else { return false }
        if childStarts.contains(where: { $0 >= t.at.addingTimeInterval(-1) }) { return false }
        switch t.name {
        case "Agent", "Task": return false                 // runs in-process for as long as it likes
        case "WebFetch", "WebSearch": return age >= 25
        default: return t.name.hasPrefix("mcp__") ? age >= 20 : age >= quiet
        }
    }

    public static func prompt(for s: SessionInfo, tool t: OpenToolUse, source: PendingPrompt.Source = .desktop) -> PendingPrompt {
        let question = t.name == "AskUserQuestion" || t.name == "ExitPlanMode"
        let summary: String
        var detail: String?
        func short(_ path: String) -> String { path.split(separator: "/").suffix(2).joined(separator: "/") }
        switch t.name {
        case "Bash":
            let cmd = t.fields["command"] ?? ""
            summary = t.fields["description"].map { "\($0): \(cmd.prefix(100))" } ?? String(cmd.prefix(120))
            detail = cmd
        case "Edit", "MultiEdit", "Write", "Read", "NotebookEdit":
            let path = t.fields["file_path"] ?? t.fields["notebook_path"] ?? ""
            summary = "\(t.name) \(short(path))"
            detail = path
        case "AskUserQuestion": summary = t.fields["question"] ?? "Claude has a question"
        case "ExitPlanMode": summary = "Claude proposed a plan"; detail = t.fields["plan"]
        default:
            summary = ChatFeed.oneLiner(tool: t.name, input: t.fields)
            detail = t.fields.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        }
        return PendingPrompt(id: s.id + "/" + t.id, chatId: s.id, profileId: s.profileId, chatTitle: s.title,
                             toolName: t.name, summary: summary, detail: detail.map { String($0.prefix(4096)) },
                             source: source, kind: question ? .question : .permission, at: t.at,
                             canAllowAlways: !question)
    }
}
