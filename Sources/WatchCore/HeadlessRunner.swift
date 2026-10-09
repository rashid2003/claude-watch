import Foundation

/// Sends a message to a chat without touching the desktop window: `claude --resume <id> -p <text>`
/// with the account's own CLI and token. Tool approvals go to the phone through the prompt tool.
public final class HeadlessRunner: @unchecked Sendable {
    public static let promptToolName = "mcp__claudewatch__approve"
    private let binary: (Profile) -> String?
    private let token: (String) -> String?
    private let promptTool: (_ sessionId: String) -> [String]?
    private let lock = NSLock()
    private var running: [String: Process] = [:]   // desktop session id -> process
    public var onExit: ((_ sessionId: String, _ status: Int32) -> Void)?

    /// `promptTool` returns the argv of the stdio MCP server for a session, or nil to run without one.
    public init(binary: @escaping (Profile) -> String? = CLIRetry.binary,
                token: @escaping (String) -> String? = TokenStore.get,
                promptTool: @escaping (_ sessionId: String) -> [String]? = { _ in nil }) {
        self.binary = binary; self.token = token; self.promptTool = promptTool
    }

    public func isRunning(sessionId: String) -> Bool { lock.withLock { running[sessionId]?.isRunning ?? false } }

    public static let busyMessage = "Claude is still working on this chat. Stop it first, or wait."
    /// Set on every run's environment, so the terminal prompt hook stays out of phone-started runs.
    public static let headlessEnv = "CLAUDE_WATCH_HEADLESS"

    /// Starts the run and returns its pid. Refuses while the chat is working (two writers would corrupt it).
    public func reply(_ text: String, session: SessionInfo, profile: Profile,
                      activity: SessionStatus.Activity) -> Result<Int32, RetryError> {
        if activity == .working || isRunning(sessionId: session.id) {
            return .failure(RetryError(message: Self.busyMessage, permanent: true))
        }
        guard let cli = session.cliSessionId else {
            return .failure(RetryError(message: "This chat has no CLI session yet", permanent: true))
        }
        // Terminal chats run as whoever their config dir's `claude` is signed into; desktop chats need their account's token.
        if session.isTerminalChat, !profile.isTerminal || profile.id != session.profileId {
            return .failure(RetryError(message: "This terminal chat's CLI config dir wasn't found", permanent: true))
        }
        let tok = session.isTerminalChat ? nil : token(profile.id)
        if tok == nil, !session.isTerminalChat {
            return .failure(RetryError(message: "No CLI token for \(profile.name). On the Mac run: claude-watch set-token \(profile.id)",
                                       permanent: true, blocked: true))
        }
        guard let bin = binary(profile) else { return .failure(RetryError(message: "claude CLI not found", permanent: true)) }

        return launch(bin, Self.arguments(cli: cli, text: text, permissionMode: session.permissionMode,
                                          promptTool: promptTool(session.id)),
                      cwd: session.cwd, env: Self.environment(base: ProcessInfo.processInfo.environment, session: session,
                                                              profile: profile, token: tok),
                      sid: session.id)
    }

    /// Starts a new chat in `cwd` as a background run: `claude -p <prompt> --session-id <new id>`, with the
    /// account's token (desktop account) or the config dir of `profile` (terminal profile). Returns the new
    /// session id; the chat shows up in the Mac's list once the CLI writes its transcript.
    public func start(prompt: String, cwd: String, profile: Profile) -> Result<String, RetryError> {
        guard FileManager.default.fileExists(atPath: cwd) else {
            return .failure(RetryError(message: "No such folder on the Mac: \(cwd)", permanent: true))
        }
        let tok: String? = profile.isTerminal ? nil : token(profile.id)
        if !profile.isTerminal, tok == nil {
            return .failure(RetryError(message: "No CLI token for \(profile.name). On the Mac run: claude-watch set-token \(profile.id)",
                                       permanent: true, blocked: true))
        }
        guard let bin = binary(profile) else {
            return .failure(RetryError(message: "claude CLI not found", permanent: true))
        }
        let sid = UUID().uuidString.lowercased()
        var args = ["-p", prompt, "--session-id", sid, "--output-format", "json"]
        if let tool = promptTool(sid), let cmd = tool.first {
            let cfg: [String: Any] = ["mcpServers": ["claudewatch": ["command": cmd, "args": Array(tool.dropFirst())]]]
            if let data = try? JSONSerialization.data(withJSONObject: cfg, options: [.sortedKeys]) {
                args += ["--mcp-config", String(decoding: data, as: UTF8.self), "--permission-prompt-tool", Self.promptToolName]
            }
        }
        let env = Self.environment(base: ProcessInfo.processInfo.environment, terminalProfile: profile.isTerminal ? profile : nil,
                                   token: tok)
        switch launch(bin, args, cwd: cwd, env: env, sid: sid) {
        case .success: return .success(sid)
        case .failure(let e): return .failure(e)
        }
    }

    private func launch(_ bin: String, _ args: [String], cwd: String, env: [String: String],
                        sid: String) -> Result<Int32, RetryError> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        if FileManager.default.fileExists(atPath: cwd) { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        p.environment = env
        let logURL = Paths.logs.appendingPathComponent("remote-\(sid)-\(Int(Date().timeIntervalSince1970)).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: logURL) { p.standardOutput = h; p.standardError = h }
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            self?.lock.withLock { if self?.running[sid] === proc { self?.running[sid] = nil } }
            self?.onExit?(sid, proc.terminationStatus)
        }
        do { try p.run() } catch {
            return .failure(RetryError(message: "Couldn't start claude: \(error.localizedDescription)"))
        }
        lock.withLock { running[sid] = p }
        return .success(p.processIdentifier)
    }

    /// The run's environment: no inherited Claude Code session or API key, the account's token for desktop
    /// chats, and for a terminal chat the `CLAUDE_CONFIG_DIR` of the dir it lives in (unset for `~/.claude`,
    /// the default dir when the app has none), so it runs with that dir's own login and never another's.
    static func environment(base: [String: String], session: SessionInfo, profile: Profile, token: String?,
                            home: URL = Paths.home) -> [String: String] {
        environment(base: base, terminalProfile: session.isTerminalChat ? profile : nil, token: token, home: home)
    }

    static func environment(base: [String: String], terminalProfile: Profile?, token: String?,
                            home: URL = Paths.home) -> [String: String] {
        var env = base.filter {
            !$0.key.hasPrefix("CLAUDE_CODE_") && $0.key != "ANTHROPIC_API_KEY" && $0.key != "CLAUDECODE"
        }
        if let token { env["CLAUDE_CODE_OAUTH_TOKEN"] = token }
        if let profile = terminalProfile, profile.id != Profile.terminalId {
            env["CLAUDE_CONFIG_DIR"] = CLIConfigDir(dir: profile.dataDir, isDefault: false, home: home).env
        }
        env[Self.headlessEnv] = "1"
        return env
    }

    static func arguments(cli: String, text: String, permissionMode: String?, promptTool: [String]?) -> [String] {
        var args = ["--resume", cli, "-p", text, "--output-format", "json"] + CLIRetry.permissionArgs(permissionMode)
        if let tool = promptTool, let cmd = tool.first, permissionMode != "bypassPermissions" {
            let cfg: [String: Any] = ["mcpServers": ["claudewatch": ["command": cmd, "args": Array(tool.dropFirst())]]]
            if let data = try? JSONSerialization.data(withJSONObject: cfg, options: [.sortedKeys]) {
                args += ["--mcp-config", String(decoding: data, as: UTF8.self), "--permission-prompt-tool", promptToolName]
            }
        }
        return args
    }

    /// Interrupts a headless run: SIGINT, then SIGTERM after 5 s. False if none is running.
    @discardableResult
    public func stop(sessionId: String) -> Bool {
        guard let p = lock.withLock({ running[sessionId] }), p.isRunning else { return false }
        kill(p.processIdentifier, SIGINT)
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if p.isRunning { p.terminate() } }
        return true
    }
}
