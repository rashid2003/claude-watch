import Foundation

/// What a chat is busy with, like the Claude app's live view: tool calls in flight, subagents and
/// background tasks. In the snapshot (`SessionStatus.work`) only running items are kept; the open chat
/// gets the full picture, including this turn's finished items and each subagent's current step.
public struct LiveWork: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable { case running, done, failed, stopped }

    /// Foreground tool calls without a result yet (subagents are in `agents`).
    public var running: [RunningTool]
    public var agents: [AgentRun]
    /// Background shells (`run_in_background`, or moved there after a timeout) and monitors.
    public var shells: [BackgroundShell]

    public init(running: [RunningTool] = [], agents: [AgentRun] = [], shells: [BackgroundShell] = []) {
        self.running = running; self.agents = agents; self.shells = shells
    }

    enum CodingKeys: String, CodingKey { case running, agents, shells }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        running = try c.decodeIfPresent([RunningTool].self, forKey: .running) ?? []
        agents = try c.decodeIfPresent([AgentRun].self, forKey: .agents) ?? []
        shells = try c.decodeIfPresent([BackgroundShell].self, forKey: .shells) ?? []
    }

    public var isEmpty: Bool { running.isEmpty && agents.isEmpty && shells.isEmpty }
    public var activeAgents: [AgentRun] { agents.filter { $0.status == .running } }
    public var activeShells: [BackgroundShell] { shells.filter { $0.status == .running } }
    public var isActive: Bool { !running.isEmpty || !activeAgents.isEmpty || !activeShells.isEmpty }

    /// Running items only, without subagent steps: the compact form sent in the snapshot. Nil when idle.
    public var brief: LiveWork? {
        let b = LiveWork(running: running,
                         agents: activeAgents.map { var a = $0; a.step = nil; a.steps = 0; return a },
                         shells: activeShells)
        return b.isEmpty ? nil : b
    }

    /// "2 agents · 1 shell · Bash: swift test", nil when nothing runs.
    public var line: String? {
        var parts: [String] = []
        let a = activeAgents.count, s = activeShells.count
        if a > 0 { parts.append(a == 1 ? "1 agent" : "\(a) agents") }
        if s > 0 { parts.append(s == 1 ? "1 shell" : "\(s) shells") }
        if let t = running.last { parts.append(t.summary) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

public struct RunningTool: Codable, Hashable, Sendable, Identifiable {
    public var id: String          // tool_use id
    public var name: String        // "Bash", "Read", ...
    public var summary: String     // "Bash: swift test", "Read App.swift"
    public var startedAt: Date

    public init(id: String, name: String, summary: String, startedAt: Date) {
        self.id = id; self.name = name; self.summary = summary; self.startedAt = startedAt
    }
}

/// A subagent (Agent / Task tool call).
public struct AgentRun: Codable, Hashable, Sendable, Identifiable {
    public var id: String          // the Agent tool_use id
    public var description: String
    public var type: String?       // "Explore", "general-purpose", ...
    public var status: LiveWork.Status
    /// Launched in the background: its result arrives later as a task notification.
    public var background: Bool
    /// Its latest tool call, e.g. "Ran swift test".
    public var step: String?
    /// Tool calls it has made.
    public var steps: Int
    public var startedAt: Date
    public var endedAt: Date?

    public init(id: String, description: String, type: String? = nil, status: LiveWork.Status = .running,
                background: Bool = false, step: String? = nil, steps: Int = 0, startedAt: Date, endedAt: Date? = nil) {
        self.id = id; self.description = description; self.type = type; self.status = status
        self.background = background; self.step = step; self.steps = steps
        self.startedAt = startedAt; self.endedAt = endedAt
    }
}

/// A background shell command or monitor.
public struct BackgroundShell: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case shell, monitor }
    public var id: String          // background task id, e.g. "b0bvijpzs"
    public var kind: Kind
    public var summary: String     // its description, else the command
    public var status: LiveWork.Status
    public var startedAt: Date
    public var endedAt: Date?

    public init(id: String, kind: Kind = .shell, summary: String, status: LiveWork.Status = .running,
                startedAt: Date, endedAt: Date? = nil) {
        self.id = id; self.kind = kind; self.summary = summary; self.status = status
        self.startedAt = startedAt; self.endedAt = endedAt
    }
}
