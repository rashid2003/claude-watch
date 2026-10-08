import Foundation

/// The opt-in Claude Code `PermissionRequest` hook (`claude-watch prompt-hook`) that lets the phone
/// answer the permission prompts of chats running in a terminal.
///
/// Claude Code runs the hook when it is about to show a permission dialog and passes the request as
/// JSON on stdin (`session_id`, `tool_name`, `tool_input`, `tool_use_id`, `cwd`, …). In an interactive
/// terminal the dialog shows at the same time and whichever answers first wins, so the terminal stays
/// usable while the hook waits. The hook forwards the request to ClaudeWatch over the prompt broker's
/// socket and prints the phone's decision:
///   allow → `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`
///   deny  → `… "decision":{"behavior":"deny","message":"…"}`
/// It prints nothing (no decision: the terminal's own prompt decides) when ClaudeWatch isn't running,
/// no phone can be asked, the wait runs out, or the request isn't from an interactive terminal chat.
public enum PromptHook {
    public static let subcommand = "prompt-hook"
    /// How long the hook waits for the phone by default.
    public static let defaultWait: TimeInterval = 300
    /// The `timeout` (seconds) written into settings.json: Claude Code kills the hook after it.
    public static let settingsTimeout = 330

    public enum Decision: Equatable {
        case allow
        case deny(String?)
        case none     // no decision: fall through to the terminal's prompt
    }

    /// The hook's stdout for a decision; nil prints nothing.
    public static func output(_ d: Decision) -> Data? {
        let decision: [String: Any]
        switch d {
        case .none: return nil
        case .allow: decision = ["behavior": "allow"]
        case .deny(let m): decision = ["behavior": "deny", "message": m ?? "Denied from the phone"]
        }
        let obj: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        return try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }

    /// Maps the broker's reply line (`{"decision":"allow"|"deny"|"defer","message"?}`) to a decision.
    public static func decision(fromBroker obj: [String: Any]?) -> Decision {
        switch obj?["decision"] as? String {
        case "allow": return .allow
        case "deny": return .deny(obj?["message"] as? String)
        default: return .none
        }
    }

    /// Requests the hook leaves to Claude Code at once: other events, desktop chats (their windows
    /// ask), phone-started runs (they ask through the prompt tool) and scripted `claude -p` runs.
    public static func shouldSkip(input: [String: Any], env: [String: String]) -> Bool {
        if let e = input["hook_event_name"] as? String, e != "PermissionRequest" { return true }
        guard let sid = input["session_id"] as? String, !sid.isEmpty else { return true }
        if env[HeadlessRunner.headlessEnv] != nil { return true }
        if let host = env["CLAUDE_CODE_HOST_SESSION_ID"], !host.isEmpty { return true }
        if let ep = env["CLAUDE_CODE_ENTRYPOINT"], ep == "claude-desktop" || ep.hasPrefix("sdk") { return true }
        return false
    }

    /// The broker request for a hook input.
    public static func request(input: [String: Any], wait: TimeInterval) -> [String: Any] {
        let tool = input["tool_name"] as? String ?? "tool"
        let toolInput = input["tool_input"] as? [String: Any] ?? [:]
        let sid = input["session_id"] as? String ?? ""
        let useId = input["tool_use_id"] as? String
        let fields = toolInput.compactMapValues { $0 as? String }
        let info = SessionInfo(id: sid, cliSessionId: sid, priorCliSessionIds: [], profileId: "", accountUuid: "",
                               title: "", cwd: input["cwd"] as? String ?? "", model: nil, permissionMode: nil,
                               lastActivityAt: Date(), isArchived: false, desktopError: nil, desktopErrorAt: nil,
                               hasPendingPermission: true)
        let p = PromptDetector.prompt(for: info, tool: OpenToolUse(id: useId ?? UUID().uuidString, name: tool,
                                                                   fields: fields, at: Date()), source: .headless)
        return ["sessionId": sid, "toolName": tool, "toolUseId": useId ?? "", "summary": p.summary,
                "detail": p.detail ?? "", "hook": true, "wait": Int(wait)]
    }

    /// Handles one hook invocation: returns what to print (nil: nothing).
    public static func run(stdin: Data, socketPath: String, wait: TimeInterval,
                           env: [String: String] = ProcessInfo.processInfo.environment) -> Data? {
        guard let input = (try? JSONSerialization.jsonObject(with: stdin)) as? [String: Any],
              !shouldSkip(input: input, env: env),
              FileManager.default.fileExists(atPath: socketPath),
              let body = try? JSONSerialization.data(withJSONObject: request(input: input, wait: wait)) else { return nil }
        let line = UnixSocket.request(path: socketPath, line: body, timeout: wait + 5)
        let obj = line.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        return output(decision(fromBroker: obj))
    }
}

/// Adds or removes the prompt hook in Claude Code's user settings (`~/.claude/settings.json`).
/// Only our own entry is touched; everything else in the file is kept. The file is backed up
/// before every change.
public enum PromptHookInstaller {
    public enum InstallError: Error, LocalizedError {
        case unreadable(String)
        public var errorDescription: String? {
            switch self { case .unreadable(let why): return "settings.json couldn't be read, so it wasn't changed: \(why)" }
        }
    }

    /// The hook command: `'<cli>' prompt-hook --socket '<socket>'` (quoted: paths have spaces).
    public static func command(cli: String, socket: String) -> String {
        "\(quote(cli)) \(PromptHook.subcommand) --socket \(quote(socket))"
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Our entries are the command hooks that run `claude-watch prompt-hook`.
    static func isOurs(_ hook: Any) -> Bool {
        guard let h = hook as? [String: Any], let cmd = h["command"] as? String else { return false }
        return cmd.contains("claude-watch") && cmd.contains(" \(PromptHook.subcommand)")
    }

    public static func isInstalled(settings url: URL) -> Bool {
        guard let obj = JSONFile.object(at: url), let hooks = obj["hooks"] as? [String: Any],
              let groups = hooks["PermissionRequest"] as? [Any] else { return false }
        return groups.contains { (($0 as? [String: Any])?["hooks"] as? [Any])?.contains(where: isOurs) == true }
    }

    /// Installs (or replaces) our hook entry. Idempotent.
    public static func install(settings link: URL, command: String, now: Date = Date()) throws {
        let url = link.resolvingSymlinksInPath()   // a dotfiles symlink stays a symlink
        var obj = try load(url)
        var hooks = obj["hooks"] as? [String: Any] ?? [:]
        if obj["hooks"] != nil, obj["hooks"] as? [String: Any] == nil { throw InstallError.unreadable("\"hooks\" isn't an object") }
        var groups = strip(hooks["PermissionRequest"])
        if hooks["PermissionRequest"] != nil, hooks["PermissionRequest"] as? [Any] == nil {
            throw InstallError.unreadable("\"hooks.PermissionRequest\" isn't a list")
        }
        groups.append(["matcher": "*",
                       "hooks": [["type": "command", "command": command, "timeout": PromptHook.settingsTimeout]]])
        hooks["PermissionRequest"] = groups
        obj["hooks"] = hooks
        try save(obj, to: url, now: now)
    }

    /// Removes our hook entry, leaving everything else. No-op (no write) when it isn't there.
    public static func remove(settings link: URL, now: Date = Date()) throws {
        let url = link.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: url.path), isInstalled(settings: url) else { return }
        var obj = try load(url)
        guard var hooks = obj["hooks"] as? [String: Any] else { return }
        let groups = strip(hooks["PermissionRequest"])
        if groups.isEmpty { hooks["PermissionRequest"] = nil } else { hooks["PermissionRequest"] = groups }
        if hooks.isEmpty { obj["hooks"] = nil } else { obj["hooks"] = hooks }
        try save(obj, to: url, now: now)
    }

    /// The PermissionRequest groups without our hooks (a group left with no hooks is dropped).
    static func strip(_ value: Any?) -> [Any] {
        guard let groups = value as? [Any] else { return [] }
        return groups.compactMap { g -> Any? in
            guard var group = g as? [String: Any], let list = group["hooks"] as? [Any] else { return g }
            let kept = list.filter { !isOurs($0) }
            if kept.count == list.count { return g }
            if kept.isEmpty { return nil }
            group["hooks"] = kept
            return group
        }
    }

    static func load(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw InstallError.unreadable(error.localizedDescription) }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw InstallError.unreadable("it isn't a JSON object")
        }
        return obj
    }

    /// Backs the current file up next to it (`settings.json.claude-watch-<time>.bak`), then writes atomically
    /// keeping its permissions.
    static func save(_ obj: [String: Any], to url: URL, now: Date) throws {
        let fm = FileManager.default
        var attrs: [FileAttributeKey: Any] = [:]
        if fm.fileExists(atPath: url.path) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd-HHmmss"
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent(url.lastPathComponent + ".claude-watch-\(f.string(from: now)).bak")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: url, to: backup)
            if let p = try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] { attrs[.posixPermissions] = p }
        } else {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
        if !attrs.isEmpty { try? fm.setAttributes(attrs, ofItemAtPath: url.path) }
    }
}
