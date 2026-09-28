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
    /// Retry requests for the engine owner, one per line (see `RetryRequest`).
    public static var retryRequest: URL { support.appendingPathComponent("retry-request") }
    public static var logs: URL {
        let url = support.appendingPathComponent("logs")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

public struct ProfileConfig: Codable, Sendable {
    public var name: String?
    public var hidden: Bool?
    public var retryMode: RetryMode?
    public init(name: String? = nil, hidden: Bool? = nil, retryMode: RetryMode? = nil) {
        self.name = name; self.hidden = hidden; self.retryMode = retryMode
    }
}

public struct Config: Codable, Sendable {
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

    public func save() throws {
        try JSONCoder.pretty.encode(self).write(to: Paths.config, options: .atomic)
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
