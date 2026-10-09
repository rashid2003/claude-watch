import Foundation

// Everything the bridge and the iPhone app exchange. JSON, dates as seconds since 1970.

public enum WireCoder {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}

// MARK: - Chat content

public struct ChatMessage: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case user, assistant, tool, error }
    public var id: String            // transcript entry uuid (+ ":n" for each content block)
    public var kind: Kind
    public var at: Date
    public var text: String          // markdown for user/assistant, a one-liner for tools
    public var toolName: String?     // "Bash", "Edit", ...
    public var toolOK: Bool?         // from the matching tool_result; nil while it runs
    public var toolUseId: String?

    public init(id: String, kind: Kind, at: Date, text: String, toolName: String? = nil,
                toolOK: Bool? = nil, toolUseId: String? = nil) {
        self.id = id; self.kind = kind; self.at = at; self.text = text
        self.toolName = toolName; self.toolOK = toolOK; self.toolUseId = toolUseId
    }
}

public struct MessagesPage: Codable, Sendable {
    public var messages: [ChatMessage]
    /// Index cursor for the previous page (index of the first message here), nil at the start of the chat
    /// or when the page carries `cursor` instead.
    public var before: Int?
    /// Opaque cursor for the previous page (pass it back as `cursor`), from Macs that read transcripts from
    /// their end; nil at the start of the chat, and from older Macs (use `before`).
    public var cursor: String?
    public init(messages: [ChatMessage], before: Int?, cursor: String? = nil) {
        self.messages = messages; self.before = before; self.cursor = cursor
    }

    /// Where the previous page starts, whichever kind of cursor this page has.
    public var older: OlderCursor? { OlderCursor(cursor: cursor, before: before) }
}

/// How to ask for the page before the messages you have: an opaque cursor (Macs that read transcripts
/// from their end) or a message index (older Macs, and the only kind older phones know).
public enum OlderCursor: Hashable, Sendable {
    case token(String)
    case index(Int)

    /// The cursor when there is one, else the index; nil when neither (the start of the chat).
    public init?(cursor: String?, before: Int?) {
        if let cursor { self = .token(cursor) } else if let before { self = .index(before) } else { return nil }
    }
}

// MARK: - Prompts

public enum PromptDecision: String, Codable, Sendable, CaseIterable { case allow, deny, allowAlways }

public struct PendingPrompt: Codable, Hashable, Sendable, Identifiable {
    public enum Source: String, Codable, Sendable { case desktop, headless }
    public enum Kind: String, Codable, Sendable {
        case permission   // a tool waiting for Allow / Deny
        case question     // AskUserQuestion / ExitPlanMode: answer it on the Mac
    }
    public var id: String
    public var chatId: String
    public var profileId: String
    public var chatTitle: String
    public var toolName: String
    public var summary: String       // "swift build", "Edit Sources/App.swift"
    public var detail: String?       // full command / path, at most 4 KB
    public var source: Source
    public var kind: Kind
    public var at: Date
    public var canAllowAlways: Bool
    /// Shown for information only: it can't be answered from the phone (a terminal chat's prompt
    /// without the prompt hook). Nil from older Macs.
    public var viewOnly: Bool? = nil

    public init(id: String, chatId: String, profileId: String, chatTitle: String, toolName: String,
                summary: String, detail: String? = nil, source: Source, kind: Kind = .permission,
                at: Date, canAllowAlways: Bool = false, viewOnly: Bool? = nil) {
        self.id = id; self.chatId = chatId; self.profileId = profileId; self.chatTitle = chatTitle
        self.toolName = toolName; self.summary = summary; self.detail = detail; self.source = source
        self.kind = kind; self.at = at; self.canAllowAlways = canAllowAlways; self.viewOnly = viewOnly
    }
}

/// A push's `aps.category`: picks the action buttons the phone shows on the notification.
public enum PushCategory {
    public static let prompt = "PROMPT"                      // Allow / Deny
    public static let promptAlways = "PROMPT_ALWAYS"         // Allow / Always / Deny
    /// Shell commands: with the app lock on, the phone asks for Face ID again, so Allow opens the app.
    public static let promptShell = "PROMPT_SHELL"
    public static let promptShellAlways = "PROMPT_SHELL_ALWAYS"
    public static let chat = "CHAT"
    public static let account = "ACCOUNT"
    public static let system = "SYSTEM"

    public static var prompts: [String] { [prompt, promptAlways, promptShell, promptShellAlways] }

    /// Questions and view-only prompts are answered on the Mac, so they get the plain chat actions.
    public static func of(_ p: PendingPrompt) -> String {
        guard p.kind == .permission, p.viewOnly != true else { return chat }
        switch (p.toolName == "Bash", p.canAllowAlways) {
        case (false, false): return prompt
        case (false, true): return promptAlways
        case (true, false): return promptShell
        case (true, true): return promptShellAlways
        }
    }
}

// MARK: - Commands and jobs

public enum JobStatus: String, Codable, Sendable {
    case accepted, running, done, failed, blocked
    public var isFinal: Bool { self == .done || self == .failed || self == .blocked }
}

public struct Job: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var requestId: String
    public var command: String       // "reply", "prompt", "stop", ...
    public var target: String?       // chat / item / profile id
    public var status: JobStatus
    public var reason: String?
    public var at: Date

    public init(id: String, requestId: String, command: String, target: String?, status: JobStatus,
                reason: String? = nil, at: Date) {
        self.id = id; self.requestId = requestId; self.command = command; self.target = target
        self.status = status; self.reason = reason; self.at = at
    }
}

/// Body of commands that need nothing but an idempotency key (stop, retry, cancel, undo, restart).
public struct PlainCommand: Codable, Sendable {
    public var requestId: String
    public init(requestId: String = UUID().uuidString) { self.requestId = requestId }
}

public struct ReplyBody: Codable, Sendable {
    public var requestId: String
    public var text: String
    public init(requestId: String = UUID().uuidString, text: String) { self.requestId = requestId; self.text = text }
}

public struct PromptAnswerBody: Codable, Sendable {
    public var requestId: String
    public var promptId: String
    public var decision: PromptDecision
    public init(requestId: String = UUID().uuidString, promptId: String, decision: PromptDecision) {
        self.requestId = requestId; self.promptId = promptId; self.decision = decision
    }
}

public enum NewChatTarget: String, Codable, Sendable { case desktop, terminal }

public struct NewChatBody: Codable, Sendable {
    public var requestId: String
    public var profileId: String
    public var cwd: String
    public var prompt: String
    /// The phone confirmed trusting a folder Claude Code hasn't been trusted in yet. Without it the Mac
    /// refuses an untrusted folder; with it, it accepts the desktop's "Trust this workspace?" prompt.
    public var trust: Bool?
    /// Where the chat starts: the account's desktop window, or a background `claude` run (a terminal chat).
    /// Absent from older phones, which mean the desktop.
    public var target: NewChatTarget?
    public init(requestId: String = UUID().uuidString, profileId: String, cwd: String, prompt: String, trust: Bool? = nil,
                target: NewChatTarget? = nil) {
        self.requestId = requestId; self.profileId = profileId; self.cwd = cwd; self.prompt = prompt; self.trust = trust
        self.target = target
    }
}

public struct ModeBody: Codable, Sendable {
    public var requestId: String
    public var mode: RetryMode
    public init(requestId: String = UUID().uuidString, mode: RetryMode) { self.requestId = requestId; self.mode = mode }
}

public struct MoveBody: Codable, Sendable {
    public var requestId: String
    public var sessionId: String
    public var toLocationId: String  // ChatLocation.id
    public init(requestId: String = UUID().uuidString, sessionId: String, toLocationId: String) {
        self.requestId = requestId; self.sessionId = sessionId; self.toLocationId = toLocationId
    }
}

public struct Accepted: Codable, Sendable {
    public var job: Job
    public init(job: Job) { self.job = job }
}

public struct WireError: Codable, Sendable, Error {
    public var error: String
    public init(_ error: String) { self.error = error }
}

// MARK: - Devices and pairing

/// Push event kinds a device can switch on or off.
public enum NotifyEvent: String, Codable, Sendable, CaseIterable {
    case prompt, finished, failed, account, system
}

public struct DeviceRegistration: Codable, Sendable {
    public var apnsToken: String?
    public var environment: String?          // "sandbox" | "production"
    public var notify: [String: Bool]?
    /// Live Activity. An empty token clears it.
    public var liveActivity: Bool?
    public var activityToken: String?
    public var activityStartToken: String?
    public init(apnsToken: String? = nil, environment: String? = nil, notify: [String: Bool]? = nil,
                liveActivity: Bool? = nil, activityToken: String? = nil, activityStartToken: String? = nil) {
        self.apnsToken = apnsToken; self.environment = environment; self.notify = notify
        self.liveActivity = liveActivity; self.activityToken = activityToken; self.activityStartToken = activityStartToken
    }
}

/// What the QR code on the Mac contains.
public struct PairingPayload: Codable, Sendable, Equatable {
    public var v: Int
    public var macName: String
    public var hosts: [String]      // MagicDNS name first, then tailnet IPs
    public var port: Int
    public var code: String
    /// v2: set when the Mac also listens through the relay.
    public var relay: RelayInfo?
    public init(macName: String, hosts: [String], port: Int, code: String, relay: RelayInfo? = nil) {
        self.v = relay == nil ? 1 : 2
        self.macName = macName; self.hosts = hosts; self.port = port; self.code = code; self.relay = relay
    }
}

public struct PairRequest: Codable, Sendable {
    public var code: String
    public var deviceName: String
    public init(code: String, deviceName: String) { self.code = code; self.deviceName = deviceName }
}

public struct PairResponse: Codable, Sendable {
    public var token: String
    public var deviceId: String
    public var macName: String
    public init(token: String, deviceId: String, macName: String) {
        self.token = token; self.deviceId = deviceId; self.macName = macName
    }
}

public struct BridgeStatus: Codable, Sendable {
    public var macName: String
    public var version: String
    public var warnings: [String]
    public var pushConfigured: Bool
    public var deviceId: String?
    public var notify: [String: Bool]
    /// The relay room and key, so a phone paired before the relay (QR v1) can pick them up.
    public var relay: RelayInfo?
    /// The Mac's `WireProtocol.current`. Nil from Macs before versions were sent (protocol 1).
    public var protocolVersion: Int?
    public init(macName: String, version: String, warnings: [String], pushConfigured: Bool,
                deviceId: String? = nil, notify: [String: Bool] = [:], relay: RelayInfo? = nil,
                protocolVersion: Int? = WireProtocol.current) {
        self.macName = macName; self.version = version; self.warnings = warnings
        self.pushConfigured = pushConfigured; self.deviceId = deviceId; self.notify = notify; self.relay = relay
        self.protocolVersion = protocolVersion
    }

    /// Which side should be updated, from this phone's point of view (`phoneProtocol` is its own number).
    public func hint(phoneProtocol: Int = WireProtocol.current) -> WireProtocol.Hint? {
        WireProtocol.hint(phone: phoneProtocol, mac: protocolVersion)
    }
}

public struct FolderSuggestion: Codable, Hashable, Sendable, Identifiable {
    public var cwd: String
    public var lastUsedAt: Date
    /// Claude Code trusts this folder (nil from Macs that don't say).
    public var trusted: Bool?
    public var id: String { cwd }
    public init(cwd: String, lastUsedAt: Date, trusted: Bool? = nil) {
        self.cwd = cwd; self.lastUsedAt = lastUsedAt; self.trusted = trusted
    }
}

/// `GET /v1/folders/check?path=`: whether a typed folder can take a new chat.
public struct FolderCheck: Codable, Hashable, Sendable {
    public var path: String
    public var exists: Bool
    public var trusted: Bool
    public init(path: String, exists: Bool, trusted: Bool) { self.path = path; self.exists = exists; self.trusted = trusted }
}

// MARK: - WebSocket

public struct WSClientMessage: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case subscribe, unsubscribe, ping, watchSystem, unwatchSystem }
    public var type: Kind
    public var chatId: String?
    /// On `subscribe`: the phone pages with opaque cursors, so the Mac may send the newest messages with a
    /// `cursor` instead of an index (`before`), which needs only the end of the transcript. Older phones leave it out.
    public var cursors: Bool?
    public init(type: Kind, chatId: String? = nil, cursors: Bool? = nil) {
        self.type = type; self.chatId = chatId; self.cursors = cursors
    }
}

public enum WSServerMessage: Sendable {
    case snapshot(Snapshot)
    /// New or updated messages of the subscribed chat (upsert by id). `reset` = replace what you have
    /// (the first batch after subscribing); `cursor` (phones that subscribed with `cursors`) or `before`
    /// is then the cursor for older pages, as in `MessagesPage`.
    case messages(chatId: String, messages: [ChatMessage], reset: Bool, before: Int?, cursor: String?)
    /// What the subscribed chat is doing (full detail), sent after subscribing and whenever it changes.
    /// Phones that don't know it skip it.
    case work(chatId: String, work: LiveWork)
    case job(Job)
    /// The Mac's resources, every 5 s while the phone watches (`watchSystem`). The first one after
    /// `watchSystem` carries the full history, later ones only the newest point.
    case system(SystemHealth)
    case pong
}

extension WSServerMessage: Codable {
    enum CodingKeys: String, CodingKey { case type, snapshot, chatId, messages, reset, before, cursor, work, job, system }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "snapshot": self = .snapshot(try c.decode(Snapshot.self, forKey: .snapshot))
        case "messages":
            self = .messages(chatId: try c.decode(String.self, forKey: .chatId),
                             messages: try c.decode([ChatMessage].self, forKey: .messages),
                             reset: try c.decodeIfPresent(Bool.self, forKey: .reset) ?? false,
                             before: try c.decodeIfPresent(Int.self, forKey: .before),
                             cursor: try c.decodeIfPresent(String.self, forKey: .cursor))
        case "work": self = .work(chatId: try c.decode(String.self, forKey: .chatId), work: try c.decode(LiveWork.self, forKey: .work))
        case "job": self = .job(try c.decode(Job.self, forKey: .job))
        case "system": self = .system(try c.decode(SystemHealth.self, forKey: .system))
        case "pong": self = .pong
        case let t: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown type \(t)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .snapshot(let s): try c.encode("snapshot", forKey: .type); try c.encode(s, forKey: .snapshot)
        case .messages(let id, let m, let reset, let before, let cursor):
            try c.encode("messages", forKey: .type); try c.encode(id, forKey: .chatId)
            try c.encode(m, forKey: .messages); try c.encode(reset, forKey: .reset)
            try c.encodeIfPresent(before, forKey: .before)
            try c.encodeIfPresent(cursor, forKey: .cursor)
        case .work(let id, let w):
            try c.encode("work", forKey: .type); try c.encode(id, forKey: .chatId); try c.encode(w, forKey: .work)
        case .job(let j): try c.encode("job", forKey: .type); try c.encode(j, forKey: .job)
        case .system(let h): try c.encode("system", forKey: .type); try c.encode(h, forKey: .system)
        case .pong: try c.encode("pong", forKey: .type)
        }
    }
}
