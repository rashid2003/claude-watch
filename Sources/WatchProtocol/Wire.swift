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
    /// Cursor for the previous page (index of the first message here), nil at the start of the chat.
    public var before: Int?
    public init(messages: [ChatMessage], before: Int?) { self.messages = messages; self.before = before }
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

    public init(id: String, chatId: String, profileId: String, chatTitle: String, toolName: String,
                summary: String, detail: String? = nil, source: Source, kind: Kind = .permission,
                at: Date, canAllowAlways: Bool = false) {
        self.id = id; self.chatId = chatId; self.profileId = profileId; self.chatTitle = chatTitle
        self.toolName = toolName; self.summary = summary; self.detail = detail; self.source = source
        self.kind = kind; self.at = at; self.canAllowAlways = canAllowAlways
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

public struct NewChatBody: Codable, Sendable {
    public var requestId: String
    public var profileId: String
    public var cwd: String
    public var prompt: String
    public init(requestId: String = UUID().uuidString, profileId: String, cwd: String, prompt: String) {
        self.requestId = requestId; self.profileId = profileId; self.cwd = cwd; self.prompt = prompt
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
    public init(macName: String, version: String, warnings: [String], pushConfigured: Bool,
                deviceId: String? = nil, notify: [String: Bool] = [:], relay: RelayInfo? = nil) {
        self.macName = macName; self.version = version; self.warnings = warnings
        self.pushConfigured = pushConfigured; self.deviceId = deviceId; self.notify = notify; self.relay = relay
    }
}

public struct FolderSuggestion: Codable, Hashable, Sendable, Identifiable {
    public var cwd: String
    public var lastUsedAt: Date
    public var id: String { cwd }
    public init(cwd: String, lastUsedAt: Date) { self.cwd = cwd; self.lastUsedAt = lastUsedAt }
}

// MARK: - WebSocket

public struct WSClientMessage: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case subscribe, unsubscribe, ping, watchSystem, unwatchSystem }
    public var type: Kind
    public var chatId: String?
    public init(type: Kind, chatId: String? = nil) { self.type = type; self.chatId = chatId }
}

public enum WSServerMessage: Sendable {
    case snapshot(Snapshot)
    /// New or updated messages of the subscribed chat (upsert by id). `reset` = replace what you have
    /// (the first batch after subscribing); `before` is then the cursor for older pages.
    case messages(chatId: String, messages: [ChatMessage], reset: Bool, before: Int?)
    case job(Job)
    /// The Mac's resources, every 5 s while the phone watches (`watchSystem`). The first one after
    /// `watchSystem` carries the full history, later ones only the newest point.
    case system(SystemHealth)
    case pong
}

extension WSServerMessage: Codable {
    enum CodingKeys: String, CodingKey { case type, snapshot, chatId, messages, reset, before, job, system }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "snapshot": self = .snapshot(try c.decode(Snapshot.self, forKey: .snapshot))
        case "messages":
            self = .messages(chatId: try c.decode(String.self, forKey: .chatId),
                             messages: try c.decode([ChatMessage].self, forKey: .messages),
                             reset: try c.decodeIfPresent(Bool.self, forKey: .reset) ?? false,
                             before: try c.decodeIfPresent(Int.self, forKey: .before))
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
        case .messages(let id, let m, let reset, let before):
            try c.encode("messages", forKey: .type); try c.encode(id, forKey: .chatId)
            try c.encode(m, forKey: .messages); try c.encode(reset, forKey: .reset)
            try c.encodeIfPresent(before, forKey: .before)
        case .job(let j): try c.encode("job", forKey: .type); try c.encode(j, forKey: .job)
        case .system(let h): try c.encode("system", forKey: .type); try c.encode(h, forKey: .system)
        case .pong: try c.encode("pong", forKey: .type)
        }
    }
}
