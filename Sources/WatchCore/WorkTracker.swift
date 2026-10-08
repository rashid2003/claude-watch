import Foundation

/// Follows what a chat is doing from its main transcript, entry by entry: tool calls without a result,
/// subagents (Agent / Task calls, sync or `async_launched`) and background shells / monitors, ended by
/// their tool_result or a `<task-notification>`. Subagent progress comes from their own transcripts
/// (`<session>/subagents/agent-<id>.jsonl`) through `step`. Cheap to feed and Codable, so the scanner
/// can keep it in its cache.
public struct WorkTracker: Codable, Sendable {
    private var tools: [String: RunningTool] = [:]       // open tool_use id -> call
    private var agents: [AgentRun] = []
    private var agentIds: [String: String] = [:]         // subagent id -> Agent tool_use id
    private var shells: [BackgroundShell] = []
    private var expires: [String: Date] = [:]            // monitor task id -> when it times out
    private var shellLabels: [String: String] = [:]      // Bash / Monitor tool_use id -> description
    private var stops: [String: String] = [:]            // TaskStop / KillShell tool_use id -> task id
    private var monitorTimeouts: [String: Double] = [:]  // Monitor tool_use id -> timeout (s), 0 = persistent

    static let keepFinished = 8
    /// Older than this and still "running", it's an orphan (the app quit mid-call) and isn't shown.
    static let staleTool: TimeInterval = 3600
    static let staleTask: TimeInterval = 12 * 3600

    public init() {}

    enum CodingKeys: String, CodingKey { case tools, agents, agentIds, shells, expires, shellLabels, stops, monitorTimeouts }

    /// Lenient, so a cache written by another version still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tools = (try? c.decodeIfPresent([String: RunningTool].self, forKey: .tools)) ?? [:]
        agents = (try? c.decodeIfPresent([AgentRun].self, forKey: .agents)) ?? []
        agentIds = (try? c.decodeIfPresent([String: String].self, forKey: .agentIds)) ?? [:]
        shells = (try? c.decodeIfPresent([BackgroundShell].self, forKey: .shells)) ?? []
        expires = (try? c.decodeIfPresent([String: Date].self, forKey: .expires)) ?? [:]
        shellLabels = (try? c.decodeIfPresent([String: String].self, forKey: .shellLabels)) ?? [:]
        stops = (try? c.decodeIfPresent([String: String].self, forKey: .stops)) ?? [:]
        monitorTimeouts = (try? c.decodeIfPresent([String: Double].self, forKey: .monitorTimeouts)) ?? [:]
    }

    /// Feeds one main-transcript entry (sidechain and meta entries are ignored).
    public mutating func consume(_ obj: [String: Any]) {
        guard obj["isSidechain"] as? Bool != true, obj["isMeta"] as? Bool != true,
              let type = obj["type"] as? String else { return }
        let at = (obj["timestamp"] as? String).flatMap(TranscriptScanner.parseISO) ?? Date()
        let msg = obj["message"] as? [String: Any] ?? [:]
        if type == "assistant" {
            for b in (msg["content"] as? [[String: Any]]) ?? [] where b["type"] as? String == "tool_use" {
                guard let id = b["id"] as? String else { continue }
                use(id: id, name: b["name"] as? String ?? "Tool", input: b["input"] as? [String: Any] ?? [:], at: at)
            }
            if msg["stop_reason"] as? String == "end_turn" { tools.removeAll() }
        } else if type == "user" {
            if let text = msg["content"] as? String { userText(text, at: at); return }
            for b in (msg["content"] as? [[String: Any]]) ?? [] {
                switch b["type"] as? String {
                case "tool_result":
                    guard let id = b["tool_use_id"] as? String else { continue }
                    result(id: id, isError: b["is_error"] as? Bool == true,
                           info: obj["toolUseResult"] as? [String: Any], at: at)
                case "text": if let t = b["text"] as? String { userText(t, at: at) }
                default: continue
                }
            }
        }
    }

    /// A tool_result seen without parsing its line (huge results): only the id and error flag.
    public mutating func result(id: String, isError: Bool, at: Date) {
        result(id: id, isError: isError, info: nil, at: at)
    }

    /// A subagent's tool call, from its own transcript. `agent` is the subagent id or its Agent tool_use id.
    public mutating func step(agent: String, tool: String, input: [String: Any]) {
        let key = agentIds[agent] ?? agent
        guard let i = agents.firstIndex(where: { $0.id == key }) else { return }
        agents[i].steps += 1
        agents[i].step = ChatFeed.oneLiner(tool: tool, input: input)
    }

    /// Ties a subagent id to its Agent call (from `agent-<id>.meta.json`'s `toolUseId`).
    public mutating func link(agent id: String, toolUseId: String) {
        if agents.contains(where: { $0.id == toolUseId }) { agentIds[id] = toolUseId }
    }

    /// Agent tool_use ids still running (whose subagent transcripts are worth following).
    public var runningAgents: [String] { agents.filter { $0.status == .running }.map(\.id) }

    /// The subagent id behind an Agent call, once known.
    public func agentId(for toolUseId: String) -> String? {
        agentIds.first { $0.value == toolUseId }?.key
    }

    /// What to show now: orphaned and expired items are dropped.
    public func live(now: Date = Date()) -> LiveWork {
        LiveWork(
            running: tools.values.filter { now.timeIntervalSince($0.startedAt) < Self.staleTool }
                .sorted { $0.startedAt < $1.startedAt },
            agents: agents.filter { $0.status != .running || now.timeIntervalSince($0.startedAt) < Self.staleTask },
            shells: shells.compactMap { s in
                guard s.status == .running else { return s }
                if now.timeIntervalSince(s.startedAt) > Self.staleTask { return nil }
                if let e = expires[s.id], e < now { return nil }
                return s
            })
    }

    // MARK: Entries

    private mutating func use(id: String, name: String, input: [String: Any], at: Date) {
        func s(_ k: String) -> String? { (input[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        switch name {
        case "Agent", "Task":
            agents.append(AgentRun(id: id, description: Self.clip(s("description") ?? s("prompt") ?? "subtask"),
                                   type: s("subagent_type"), background: input["run_in_background"] as? Bool == true,
                                   startedAt: at))
            return
        case "Bash":
            shellLabels[id] = Self.clip(s("description") ?? s("command") ?? "command")
        case "Monitor":
            shellLabels[id] = Self.clip(s("description") ?? s("command") ?? "monitor")
            let persistent = input["persistent"] as? Bool == true
            monitorTimeouts[id] = persistent ? 0 : ((input["timeout_ms"] as? NSNumber)?.doubleValue ?? 300_000) / 1000
        case "TaskStop", "KillShell", "KillBash":
            if let t = s("task_id") ?? s("shell_id") ?? s("bash_id") { stops[id] = t }
        default: break
        }
        tools[id] = RunningTool(id: id, name: name, summary: Self.label(tool: name, input: input), startedAt: at)
    }

    private mutating func result(id: String, isError: Bool, info: [String: Any]?, at: Date) {
        let tool = tools.removeValue(forKey: id)
        let label = shellLabels.removeValue(forKey: id)
        let timeout = monitorTimeouts.removeValue(forKey: id)
        if let task = stops.removeValue(forKey: id), !isError { end([task], status: .stopped, at: at) }

        if let i = agents.firstIndex(where: { $0.id == id }) {
            if let a = info?["agentId"] as? String { agentIds[a] = id }
            if info?["status"] as? String == "async_launched" || info?["isAsync"] as? Bool == true, !isError {
                agents[i].background = true
            } else if agents[i].status == .running {
                agents[i].status = isError ? .failed : .done
                agents[i].endedAt = at
                if let n = (info?["totalToolUseCount"] as? NSNumber)?.intValue { agents[i].steps = max(agents[i].steps, n) }
            }
            return
        }
        guard let tool, !isError, let info else { return }
        if tool.name == "Bash", let task = info["backgroundTaskId"] as? String {
            addShell(BackgroundShell(id: task, kind: .shell, summary: label ?? tool.summary, startedAt: at))
        } else if tool.name == "Monitor", let task = info["taskId"] as? String {
            addShell(BackgroundShell(id: task, kind: .monitor, summary: label ?? tool.summary, startedAt: at))
            if let t = timeout, t > 0 { expires[task] = at.addingTimeInterval(t) }
        }
    }

    private mutating func userText(_ raw: String, at: Date) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("<task-notification>") { return notification(t, at: at) }
        if t.hasPrefix("[Request interrupted") { return interrupted(at: at) }
        guard ChatParser.userText(t) != nil else { return }
        newTurn()
    }

    /// `<task-notification>` with task ids, maybe the Agent's tool-use id, and a final `<status>`.
    /// Monitor events carry no status and leave the monitor running.
    private mutating func notification(_ t: String, at: Date) {
        guard let status = Self.tags("status", in: t).first else { return }
        let s: LiveWork.Status = switch status {
        case "completed": .done
        case "failed": .failed
        default: .stopped
        }
        let ids = Self.tags("task-id", in: t) + Self.tags("tool-use-id", in: t)
        end(ids, status: s, at: at)
        if let n = Self.tags("tool_uses", in: t).first.flatMap(Int.init) {
            for id in ids {
                let key = agentIds[id] ?? id
                if let i = agents.firstIndex(where: { $0.id == key }) { agents[i].steps = max(agents[i].steps, n) }
            }
        }
    }

    private mutating func end(_ ids: [String], status: LiveWork.Status, at: Date) {
        for id in ids {
            let key = agentIds[id] ?? id
            if let i = agents.firstIndex(where: { $0.id == key && $0.status == .running }) {
                agents[i].status = status
                agents[i].endedAt = at
            }
            if let i = shells.firstIndex(where: { $0.id == id && $0.status == .running }) {
                shells[i].status = status
                shells[i].endedAt = at
                expires[id] = nil
            }
        }
    }

    /// The user stopped the turn: calls in flight and foreground subagents end with it.
    private mutating func interrupted(at: Date) {
        tools.removeAll()
        for i in agents.indices where agents[i].status == .running && !agents[i].background {
            agents[i].status = .stopped
            agents[i].endedAt = at
        }
    }

    /// A new prompt: last turn's finished items go; background work carries on.
    private mutating func newTurn() {
        tools.removeAll()
        shellLabels.removeAll()
        stops.removeAll()
        monitorTimeouts.removeAll()
        agents.removeAll { $0.status != .running || !$0.background }
        shells.removeAll { $0.status != .running }
        let live = Set(agents.map(\.id))
        agentIds = agentIds.filter { live.contains($0.value) }
    }

    private mutating func addShell(_ s: BackgroundShell) {
        shells.append(s)
        let done = shells.filter { $0.status != .running }
        if done.count > Self.keepFinished, let oldest = done.first { shells.removeAll { $0.id == oldest.id } }
    }

    // MARK: Text

    /// "Bash: swift test" for commands, the transcript one-liner ("Read App.swift") otherwise.
    static func label(tool: String, input: [String: Any]) -> String {
        if tool == "Bash", let c = input["command"] as? String, !c.isEmpty { return "Bash: " + clip(c) }
        return ChatFeed.oneLiner(tool: tool, input: input)
    }

    static func clip(_ t: String, _ n: Int = 80) -> String {
        let one = t.split(whereSeparator: \.isNewline).first.map(String.init) ?? t
        return one.count > n ? String(one.prefix(n)) + "…" : one
    }

    /// Every `<tag>value</tag>` in `text`.
    static func tags(_ tag: String, in text: String) -> [String] {
        var out: [String] = []
        var rest = text[...]
        while let a = rest.range(of: "<\(tag)>"), let b = rest[a.upperBound...].range(of: "</\(tag)>") {
            out.append(String(rest[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespaces))
            rest = rest[b.upperBound...]
        }
        return out
    }
}

/// Follows the subagent transcripts of a chat (`<session>/subagents/`) while their Agent calls run,
/// feeding each new tool call to a `WorkTracker`. Only appended bytes are read.
struct SubagentFeeds {
    let dir: URL
    private var offsets: [String: UInt64] = [:]      // subagent id -> bytes read
    private var linked: [String: String] = [:]       // subagent id -> Agent tool_use id (from meta.json)
    private var listedAt = Date.distantPast

    init(transcript: URL) {
        dir = transcript.deletingPathExtension().appendingPathComponent("subagents")
    }

    mutating func poll(_ tracker: inout WorkTracker, now: Date = Date()) {
        let running = tracker.runningAgents
        guard !running.isEmpty else { return }
        // A running Agent whose subagent file isn't known yet: look again, at most every 2 s.
        let unknown = running.filter { tracker.agentId(for: $0) == nil && !linked.values.contains($0) }
        if !unknown.isEmpty, now.timeIntervalSince(listedAt) > 2 {
            listedAt = now
            let fm = FileManager.default
            for f in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasPrefix("agent-") && f.hasSuffix(".meta.json") {
                let id = String(f.dropFirst(6).dropLast(10))
                guard linked[id] == nil,
                      let data = fm.contents(atPath: dir.appendingPathComponent(f).path),
                      let meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let use = meta["toolUseId"] as? String else { continue }
                linked[id] = use
            }
        }
        for (id, use) in linked { tracker.link(agent: id, toolUseId: use) }
        for use in running {
            guard let id = tracker.agentId(for: use) else { continue }
            read(id, use: use, into: &tracker)
        }
    }

    private mutating func read(_ id: String, use: String, into tracker: inout WorkTracker) {
        let url = dir.appendingPathComponent("agent-\(id).jsonl")
        let offset = offsets[id] ?? 0
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
              size.uint64Value > offset, let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        try? h.seek(toOffset: offset)
        let data = (try? h.readToEnd()) ?? Data()
        guard let lastNL = data.lastIndex(of: 0x0A) else { return }
        for line in data[..<lastNL].split(separator: 0x0A) {
            // Only assistant entries with tool calls; tool results can be huge, skip them unparsed.
            guard line.prefix(2048).range(of: Data("\"type\":\"assistant\"".utf8)) != nil,
                  line.range(of: Data("\"tool_use\"".utf8)) != nil,
                  let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            for b in content where b["type"] as? String == "tool_use" {
                tracker.step(agent: use, tool: b["name"] as? String ?? "Tool", input: b["input"] as? [String: Any] ?? [:])
            }
        }
        offsets[id] = offset + UInt64(lastNL - data.startIndex + 1)
    }
}
