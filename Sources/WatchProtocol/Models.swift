import Foundation

// Types shared by the Mac (WatchCore, the bridge) and the iPhone app. Public memberwise
// initialisers are spelled out because Swift only synthesises internal ones.

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

    public init(id: String, name: String, dataDir: URL, launcherApp: URL? = nil) {
        self.id = id; self.name = name; self.dataDir = dataDir; self.launcherApp = launcherApp
    }
}

public struct UsageSample: Codable, Hashable, Sendable {
    public var t: Date
    public var org: String
    public var fiveHour: Double
    public var weekly: Double

    public init(t: Date, org: String, fiveHour: Double, weekly: Double) {
        self.t = t; self.org = org; self.fiveHour = fiveHour; self.weekly = weekly
    }
}

public struct TaskItem: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable { case pending, in_progress, completed }
    public var id: String
    public var subject: String
    public var activeForm: String?
    public var status: Status

    public init(id: String, subject: String, activeForm: String? = nil, status: Status) {
        self.id = id; self.subject = subject; self.activeForm = activeForm; self.status = status
    }
}

public struct RateLimitHit: Codable, Hashable, Sendable {
    public var at: Date
    public var resetsAt: Date?
    public var kind: LimitKind
    public var text: String

    public init(at: Date, resetsAt: Date? = nil, kind: LimitKind, text: String) {
        self.at = at; self.resetsAt = resetsAt; self.kind = kind; self.text = text
    }
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

    public init(last: Last = .none, lastAt: Date? = nil, lastRateLimit: RateLimitHit? = nil, lastSuccessAt: Date? = nil) {
        self.last = last; self.lastAt = lastAt; self.lastRateLimit = lastRateLimit; self.lastSuccessAt = lastSuccessAt
    }
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

    public init(id: String, cliSessionId: String?, priorCliSessionIds: [String], profileId: String,
                accountUuid: String, title: String, cwd: String, model: String?, permissionMode: String?,
                lastActivityAt: Date, isArchived: Bool, desktopError: String?, desktopErrorAt: Date?,
                hasPendingPermission: Bool, recordModifiedAt: Date = .distantPast, folder: String = "") {
        self.id = id; self.cliSessionId = cliSessionId; self.priorCliSessionIds = priorCliSessionIds
        self.profileId = profileId; self.accountUuid = accountUuid; self.title = title; self.cwd = cwd
        self.model = model; self.permissionMode = permissionMode; self.lastActivityAt = lastActivityAt
        self.isArchived = isArchived; self.desktopError = desktopError; self.desktopErrorAt = desktopErrorAt
        self.hasPendingPermission = hasPendingPermission; self.recordModifiedAt = recordModifiedAt
        self.folder = folder
    }
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

    public init(info: SessionInfo, activity: Activity, tail: TranscriptTail, tasks: [TaskItem],
                tokens5h: Double, tokens7d: Double) {
        self.info = info; self.activity = activity; self.tail = tail; self.tasks = tasks
        self.tokens5h = tokens5h; self.tokens7d = tokens7d
    }
}

public struct LimitForecast: Codable, Hashable, Sendable {
    public var percent: Double?        // best estimate "now"
    public var samplePercent: Double?  // last observed by the desktop app
    public var sampleAt: Date?
    public var ratePerHour: Double?    // % per hour
    public var hitsAt: Date?           // projected time the cap is reached
    public var resetsAt: Date?
    public var resetsFirst: Bool       // the window resets before the cap is hit

    public init(percent: Double? = nil, samplePercent: Double? = nil, sampleAt: Date? = nil, ratePerHour: Double? = nil,
                hitsAt: Date? = nil, resetsAt: Date? = nil, resetsFirst: Bool = false) {
        self.percent = percent; self.samplePercent = samplePercent; self.sampleAt = sampleAt
        self.ratePerHour = ratePerHour; self.hitsAt = hitsAt; self.resetsAt = resetsAt; self.resetsFirst = resetsFirst
    }
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

    public init(profile: Profile, memberProfileIds: [String], alsoOpenIn: [String], accountUuid: String?,
                running: Bool, pid: Int32?, state: AccountState, limitedUntil: Date?, limitKind: LimitKind?,
                fiveHour: LimitForecast, weekly: LimitForecast, tokens5h: Double, tokens7d: Double,
                tokensPerHourNow: Double, sessions: [SessionStatus], retryMode: RetryMode) {
        self.profile = profile; self.memberProfileIds = memberProfileIds; self.alsoOpenIn = alsoOpenIn
        self.accountUuid = accountUuid; self.running = running; self.pid = pid; self.state = state
        self.limitedUntil = limitedUntil; self.limitKind = limitKind; self.fiveHour = fiveHour
        self.weekly = weekly; self.tokens5h = tokens5h; self.tokens7d = tokens7d
        self.tokensPerHourNow = tokensPerHourNow; self.sessions = sessions; self.retryMode = retryMode
    }
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
    /// Permission prompts / questions waiting on the user, across every account.
    public var prompts: [PendingPrompt] = []

    public init(at: Date, accounts: [AccountStatus], queue: [RetryItem], engineOwner: Bool, scanning: Bool,
                moves: [PendingMove] = [], locations: [ChatLocation] = [], profiles: [Profile] = [],
                prompts: [PendingPrompt] = []) {
        self.at = at; self.accounts = accounts; self.queue = queue; self.engineOwner = engineOwner
        self.scanning = scanning; self.moves = moves; self.locations = locations; self.profiles = profiles
        self.prompts = prompts
    }

    enum CodingKeys: String, CodingKey { case at, accounts, queue, engineOwner, scanning, moves, locations, profiles, prompts }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = try c.decode(Date.self, forKey: .at)
        accounts = try c.decode([AccountStatus].self, forKey: .accounts)
        queue = try c.decode([RetryItem].self, forKey: .queue)
        engineOwner = try c.decode(Bool.self, forKey: .engineOwner)
        scanning = try c.decode(Bool.self, forKey: .scanning)
        moves = try c.decodeIfPresent([PendingMove].self, forKey: .moves) ?? []
        locations = try c.decodeIfPresent([ChatLocation].self, forKey: .locations) ?? []
        profiles = try c.decodeIfPresent([Profile].self, forKey: .profiles) ?? []
        prompts = try c.decodeIfPresent([PendingPrompt].self, forKey: .prompts) ?? []
    }

    /// Every listed chat across accounts, newest activity first.
    public var sessions: [SessionStatus] {
        accounts.flatMap(\.sessions).sorted { $0.info.lastActivityAt > $1.info.lastActivityAt }
    }

    public func account(forProfile id: String) -> AccountStatus? {
        accounts.first { $0.memberProfileIds.contains(id) }
    }
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

    public init(sessionId: String, cliSessionId: String?, profileId: String, title: String, cwd: String,
                failedAt: Date, resetsAt: Date?, status: Status, attempts: Int, lastAttemptAt: Date?,
                lastMode: RetryMode?, note: String?) {
        self.sessionId = sessionId; self.cliSessionId = cliSessionId; self.profileId = profileId
        self.title = title; self.cwd = cwd; self.failedAt = failedAt; self.resetsAt = resetsAt
        self.status = status; self.attempts = attempts; self.lastAttemptAt = lastAttemptAt
        self.lastMode = lastMode; self.note = note
    }
}

public struct RetryLogEntry: Codable, Sendable {
    public var at: Date
    public var sessionId: String
    public var profileId: String
    public var mode: RetryMode
    public var outcome: String   // sent, send_failed, verified, relimited, no_response
    public var detail: String?
    public var latencySeconds: Double?

    public init(at: Date, sessionId: String, profileId: String, mode: RetryMode, outcome: String,
                detail: String? = nil, latencySeconds: Double? = nil) {
        self.at = at; self.sessionId = sessionId; self.profileId = profileId; self.mode = mode
        self.outcome = outcome; self.detail = detail; self.latencySeconds = latencySeconds
    }
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

    public init(id: String, cliSessionId: String?, title: String, cwd: String, lastActivityAt: Date,
                isArchived: Bool, location: ChatLocation) {
        self.id = id; self.cliSessionId = cliSessionId; self.title = title; self.cwd = cwd
        self.lastActivityAt = lastActivityAt; self.isArchived = isArchived; self.location = location
    }
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

    public init(id: String, sessionId: String, title: String, from: ChatLocation, to: ChatLocation,
                createdAt: Date, status: Status, finishedAt: Date? = nil, note: String? = nil,
                backupDir: String? = nil, undoOf: String? = nil) {
        self.id = id; self.sessionId = sessionId; self.title = title; self.from = from; self.to = to
        self.createdAt = createdAt; self.status = status; self.finishedAt = finishedAt; self.note = note
        self.backupDir = backupDir; self.undoOf = undoOf
    }
}
