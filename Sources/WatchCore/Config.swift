import Foundation

public enum Paths {
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    public static var claudeHome: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        return home.appendingPathComponent(".claude")
    }
    public static var projects: URL { claudeHome.appendingPathComponent("projects") }
    public static var tasks: URL { claudeHome.appendingPathComponent("tasks") }
    public static var defaultProfile: URL { home.appendingPathComponent("Library/Application Support/Claude") }
    public static var profilesRoot: URL { home.appendingPathComponent("Claude-Profiles") }

    public static var support: URL {
        let url = home.appendingPathComponent("Library/Application Support/claude-watch")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    public static var config: URL { support.appendingPathComponent("config.json") }
    public static var state: URL { support.appendingPathComponent("state.json") }
    public static var scanCache: URL { support.appendingPathComponent("scan-cache.json") }
    public static var retryLog: URL { support.appendingPathComponent("retry-log.jsonl") }
    public static var engineLock: URL { support.appendingPathComponent("engine.lock") }
    public static var devices: URL { support.appendingPathComponent("devices.json") }
    public static var remoteLog: URL { support.appendingPathComponent("remote-log.jsonl") }
    /// This Mac's relay room and keys (0600).
    public static var relayIdentity: URL { support.appendingPathComponent("relay.json") }
    /// Unix socket for headless approval requests (paths are limited to 104 bytes).
    public static var bridgeSocket: String { support.appendingPathComponent("bridge.sock").path }
    /// Retry requests for the engine owner, one per line (see `RetryRequest`).
    public static var retryRequest: URL { support.appendingPathComponent("retry-request") }
    public static var logs: URL {
        let url = support.appendingPathComponent("logs")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

public struct ProfileConfig: Codable, Sendable, Equatable {
    public var name: String?
    public var hidden: Bool?
    public var retryMode: RetryMode?
    public init(name: String? = nil, hidden: Bool? = nil, retryMode: RetryMode? = nil) {
        self.name = name; self.hidden = hidden; self.retryMode = retryMode
    }
}

public struct SystemConfig: Codable, Sendable, Equatable {
    public var diskWarnGB: Double = 50
    public var diskCriticalGB: Double = 20
    public var auto = AutoActConfig()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SystemConfig()
        diskWarnGB = try c.decodeIfPresent(Double.self, forKey: .diskWarnGB) ?? d.diskWarnGB
        diskCriticalGB = try c.decodeIfPresent(Double.self, forKey: .diskCriticalGB) ?? d.diskCriticalGB
        auto = try c.decodeIfPresent(AutoActConfig.self, forKey: .auto) ?? d.auto
    }
}

/// What Session Watch does on its own once the Mac has stayed critical for `afterSeconds`. Off by default.
public struct AutoActConfig: Codable, Sendable, Equatable {
    public var enabled = false
    public var afterSeconds = 120
    /// `AppUsage.id` (bundle path) or a process name (for loose processes, whose pids change).
    public var quitApps: [String] = []
    /// SIGKILL apps still running 30 s after the polite quit.
    public var forceIfStuck = false
    public var closeIdleClaude = false
    /// Cleaned only when disk is a critical signal. Never "trash".
    public var cleanTargets: [String] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AutoActConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        afterSeconds = try c.decodeIfPresent(Int.self, forKey: .afterSeconds) ?? d.afterSeconds
        quitApps = try c.decodeIfPresent([String].self, forKey: .quitApps) ?? d.quitApps
        forceIfStuck = try c.decodeIfPresent(Bool.self, forKey: .forceIfStuck) ?? d.forceIfStuck
        closeIdleClaude = try c.decodeIfPresent(Bool.self, forKey: .closeIdleClaude) ?? d.closeIdleClaude
        cleanTargets = (try c.decodeIfPresent([String].self, forKey: .cleanTargets) ?? d.cleanTargets).filter { $0 != "trash" }
    }

    public var summary: AutoActSummary {
        AutoActSummary(enabled: enabled, afterSeconds: afterSeconds, quitApps: quitApps,
                       closeIdleClaude: closeIdleClaude, cleanTargets: cleanTargets)
    }
}

public struct Config: Codable, Sendable, Equatable {
    public var pollSeconds: Double = 15
    public var defaultRetryMode: RetryMode = .ui
    public var retryMessage: String = "continue"
    public var retryDelaySeconds: Double = 60
    public var maxAttempts: Int = 3
    /// Chats that failed longer ago than this are not queued automatically.
    public var maxFailureAgeHours: Double = 12
    public var verifyTimeoutSeconds: Double = 240
    public var warnBeforeCapMinutes: Double = 30
    public var profiles: [String: ProfileConfig] = [:]
    /// Extra args for CLI-mode retries, e.g. ["--permission-mode", "acceptEdits"].
    /// Empty = mirror the session's own permission mode.
    public var cliExtraArgs: [String] = []
    /// Display names for org UUIDs, used in "move to" menus. Unknown orgs show their first 8 characters.
    public var orgNames: [String: String] = [:]
    /// iPhone remote (ClaudeRemote): listens on the Tailscale addresses and 127.0.0.1.
    public var bridgeEnabled: Bool = true
    public var bridgePort: Int = 7433
    /// Prevent idle sleep while a phone is paired, so it can reach the Mac.
    public var keepAwakeWhenPaired: Bool = false
    public var keepAwakeOnlyOnAC: Bool = true
    /// Only accept phones signed into the same Tailscale account as this Mac (`tailscale whois`).
    public var requireTailnetOwner: Bool = true
    /// Also reachable through the Session Watch relay, so phones need no Tailscale. End-to-end encrypted.
    public var relayEnabled: Bool = true
    public var relayURL: String = "wss://relay.sessionwatch.lajward.co"
    /// Mac app appearance: the menu bar item and the Dock icon (at least one stays on).
    public var showInMenuBar: Bool = true
    public var showInDock: Bool = true
    /// System health: disk thresholds and the opt-in auto-act.
    public var system = SystemConfig()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        pollSeconds = try c.decodeIfPresent(Double.self, forKey: .pollSeconds) ?? d.pollSeconds
        defaultRetryMode = try c.decodeIfPresent(RetryMode.self, forKey: .defaultRetryMode) ?? d.defaultRetryMode
        retryMessage = try c.decodeIfPresent(String.self, forKey: .retryMessage) ?? d.retryMessage
        retryDelaySeconds = try c.decodeIfPresent(Double.self, forKey: .retryDelaySeconds) ?? d.retryDelaySeconds
        maxAttempts = try c.decodeIfPresent(Int.self, forKey: .maxAttempts) ?? d.maxAttempts
        maxFailureAgeHours = try c.decodeIfPresent(Double.self, forKey: .maxFailureAgeHours) ?? d.maxFailureAgeHours
        verifyTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .verifyTimeoutSeconds) ?? d.verifyTimeoutSeconds
        warnBeforeCapMinutes = try c.decodeIfPresent(Double.self, forKey: .warnBeforeCapMinutes) ?? d.warnBeforeCapMinutes
        profiles = try c.decodeIfPresent([String: ProfileConfig].self, forKey: .profiles) ?? [:]
        cliExtraArgs = try c.decodeIfPresent([String].self, forKey: .cliExtraArgs) ?? []
        orgNames = try c.decodeIfPresent([String: String].self, forKey: .orgNames) ?? [:]
        bridgeEnabled = try c.decodeIfPresent(Bool.self, forKey: .bridgeEnabled) ?? d.bridgeEnabled
        bridgePort = try c.decodeIfPresent(Int.self, forKey: .bridgePort) ?? d.bridgePort
        keepAwakeWhenPaired = try c.decodeIfPresent(Bool.self, forKey: .keepAwakeWhenPaired) ?? d.keepAwakeWhenPaired
        keepAwakeOnlyOnAC = try c.decodeIfPresent(Bool.self, forKey: .keepAwakeOnlyOnAC) ?? d.keepAwakeOnlyOnAC
        requireTailnetOwner = try c.decodeIfPresent(Bool.self, forKey: .requireTailnetOwner) ?? d.requireTailnetOwner
        relayEnabled = try c.decodeIfPresent(Bool.self, forKey: .relayEnabled) ?? d.relayEnabled
        relayURL = try c.decodeIfPresent(String.self, forKey: .relayURL) ?? d.relayURL
        showInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showInMenuBar) ?? d.showInMenuBar
        showInDock = try c.decodeIfPresent(Bool.self, forKey: .showInDock) ?? d.showInDock
        system = try c.decodeIfPresent(SystemConfig.self, forKey: .system) ?? d.system
    }

    public func retryMode(for profileId: String) -> RetryMode {
        profiles[profileId]?.retryMode ?? defaultRetryMode
    }

    public static func load() -> Config {
        guard let data = try? Data(contentsOf: Paths.config),
              let cfg = try? JSONCoder.decoder.decode(Config.self, from: data) else {
            let cfg = Config()
            if !FileManager.default.fileExists(atPath: Paths.config.path) { try? cfg.save() }
            return cfg
        }
        return cfg
    }

    public func save() throws { try save(to: Paths.config) }

    /// Writes atomically (temp file + rename), so a reader never sees half a file.
    public func save(to url: URL) throws {
        try JSONCoder.pretty.encode(self).write(to: url, options: .atomic)
    }

    public static func load(from url: URL) -> Config? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONCoder.decoder.decode(Config.self, from: data)
    }
}

public enum JSONCoder {
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()
    public static let pretty: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}
