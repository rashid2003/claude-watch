import Foundation

public enum RetryMode: String, Codable, CaseIterable, Sendable {
    case ui, cli, off
}

public enum AccountState: String, Codable, Sendable {
    case free, working, limited, offline
}

public enum LimitKind: String, Codable, Sendable {
    case fiveHour = "five_hour"
    case weekly = "seven_day"
    case other

    public init(apiValue: String?) {
        switch apiValue {
        case "five_hour": self = .fiveHour
        case let v? where v.hasPrefix("seven_day") || v.contains("week"): self = .weekly
        default: self = .other
        }
    }
}

/// A Claude desktop user-data directory (one per launcher app).
public struct Profile: Codable, Hashable, Sendable, Identifiable {
    public var id: String          // "default", "account-1", ...
    public var name: String        // display name
    public var dataDir: URL
    public var launcherApp: URL?   // applet that starts this profile, if any

    public var isDefault: Bool { id == "default" }
}

public struct UsageSample: Codable, Hashable, Sendable {
    public var t: Date
    public var org: String
    public var fiveHour: Double
    public var weekly: Double
}

public struct TaskItem: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable { case pending, in_progress, completed }
    public var id: String
    public var subject: String
    public var activeForm: String?
    public var status: Status
}

public struct RateLimitHit: Codable, Hashable, Sendable {
    public var at: Date
    public var resetsAt: Date?
    public var kind: LimitKind
    public var text: String
}

/// What the tail of a transcript says about the session.
public struct TranscriptTail: Codable, Hashable, Sendable {
    public enum Last: String, Codable, Sendable {
        case none, userPrompt, toolResult, assistantTool, assistantDone, rateLimited, apiError
    }
    public var last: Last = .none
    public var lastAt: Date?
    public var lastRateLimit: RateLimitHit?
    public var lastSuccessAt: Date?
}

public struct SessionInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: String              // desktop local id: local_...
    public var cliSessionId: String?
    public var priorCliSessionIds: [String]
    public var profileId: String
    public var accountUuid: String
    public var title: String
    public var cwd: String
    public var model: String?
    public var permissionMode: String?
    public var lastActivityAt: Date
    public var isArchived: Bool
    public var desktopError: String?
    public var desktopErrorAt: Date?
    public var hasPendingPermission: Bool
    public var recordModifiedAt: Date = .distantPast
    public var folder: String = ""     // "account/org" folder the record lives in
}

public struct SessionStatus: Codable, Hashable, Sendable, Identifiable {
    public enum Activity: String, Codable, Sendable { case working, waiting, idle, failed }
    public var info: SessionInfo
    public var activity: Activity
    public var tail: TranscriptTail
    public var tasks: [TaskItem]
    public var tokens5h: Double        // weighted, trailing 5h
    public var tokens7d: Double
    public var id: String { info.id }
}

public struct LimitForecast: Codable, Hashable, Sendable {
    public var percent: Double?        // best estimate "now"
    public var samplePercent: Double?  // last observed by the desktop app
    public var sampleAt: Date?
    public var ratePerHour: Double?    // % per hour
    public var hitsAt: Date?           // projected time the cap is reached
    public var resetsAt: Date?
    public var resetsFirst: Bool       // the window resets before the cap is hit
}

public struct AccountStatus: Codable, Hashable, Sendable, Identifiable {
    public var profile: Profile            // primary window for this account
    public var memberProfileIds: [String]  // every profile signed into this account
    public var alsoOpenIn: [String]
    public var accountUuid: String?
    public var running: Bool
    public var pid: Int32?
    public var state: AccountState
    public var limitedUntil: Date?
    public var limitKind: LimitKind?
    public var fiveHour: LimitForecast
    public var weekly: LimitForecast
    public var tokens5h: Double
    public var tokens7d: Double
    public var tokensPerHourNow: Double  // weighted, last 30 min
    public var sessions: [SessionStatus] // recent / relevant, newest first
    public var retryMode: RetryMode
    public var id: String { profile.id }
}

public struct Snapshot: Codable, Sendable {
    public var at: Date
    public var accounts: [AccountStatus]
    public var queue: [RetryItem]
    public var engineOwner: Bool
    public var scanning: Bool
    public var moves: [PendingMove] = []
    public var locations: [ChatLocation] = []
    public var profiles: [Profile] = []
}

public struct RetryItem: Codable, Hashable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable { case waiting, running, verifying, done, failed, resolved }
    public var id: String { sessionId + "@" + String(Int(failedAt.timeIntervalSince1970)) }
    public var sessionId: String
    public var cliSessionId: String?
    public var profileId: String
    public var title: String
    public var cwd: String
    public var failedAt: Date
    public var resetsAt: Date?
    public var status: Status
    public var attempts: Int
    public var lastAttemptAt: Date?
    public var lastMode: RetryMode?
    public var note: String?
    /// The last send was a user-requested "Retry now": its outcome doesn't count toward maxAttempts.
    public var lastSendManual: Bool? = nil
}

public struct RetryLogEntry: Codable, Sendable {
    public var at: Date
    public var sessionId: String
    public var profileId: String
    public var mode: RetryMode
    public var outcome: String   // sent, send_failed, verified, relimited, no_response
    public var detail: String?
    public var latencySeconds: Double?
}

/// A place a chat record can live: one profile window, signed into one account + org.
public struct ChatLocation: Codable, Hashable, Sendable, Identifiable {
    public var profileId: String
    public var accountUuid: String
    public var orgUuid: String
    public var profileName: String
    public var label: String           // "<profile name> · <org name>"
    public var chatCount: Int
    public var id: String { profileId + "/" + accountUuid + "/" + orgUuid }

    public init(profileId: String, accountUuid: String, orgUuid: String,
                profileName: String = "", label: String = "", chatCount: Int = 0) {
        self.profileId = profileId; self.accountUuid = accountUuid; self.orgUuid = orgUuid
        self.profileName = profileName.isEmpty ? profileId : profileName
        self.label = label.isEmpty ? profileId : label
        self.chatCount = chatCount
    }
}

/// One chat record as listed in the All chats window.
public struct ChatRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String              // local_…
    public var cliSessionId: String?
    public var title: String
    public var cwd: String
    public var lastActivityAt: Date
    public var isArchived: Bool
    public var location: ChatLocation
}

public struct PendingMove: Codable, Hashable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable { case pending, done, failed, conflict, undone }
    public var id: String
    public var sessionId: String
    public var title: String
    public var from: ChatLocation
    public var to: ChatLocation
    public var createdAt: Date
    public var status: Status
    public var finishedAt: Date?
    public var note: String?
    public var backupDir: String?
    public var undoOf: String?
}
