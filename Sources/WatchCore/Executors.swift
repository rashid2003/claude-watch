import AppKit
import ApplicationServices
import Foundation
import Security

// MARK: - Keychain (per-profile OAuth token for CLI-mode retries)

public enum TokenStore {
    static let service = "claude-watch"

    public static func get(_ profileId: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: profileId,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult
    public static func set(_ token: String, for profileId: String) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: profileId]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrLabel as String] = "claude-watch token (\(profileId))"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public static func remove(_ profileId: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service,
                       kSecAttrAccount as String: profileId] as CFDictionary)
    }
}

// MARK: - Opening a session inside a specific Claude instance

public enum DesktopLink {
    /// Sends `claude://code/continue?session=<id>` to one specific Claude process via a
    /// GetURL Apple event, so the right account's window handles it.
    public static func openSession(_ sessionId: String, pid: Int32) -> Bool {
        var c = URLComponents()
        c.scheme = "claude"; c.host = "code"; c.path = "/continue"
        c.queryItems = [URLQueryItem(name: "session", value: sessionId)]
        guard let url = c.string else { return false }
        return sendGetURL(url, pid: pid)
    }

    static func sendGetURL(_ url: String, pid: Int32) -> Bool {
        let gurl: AEEventClass = 0x4755_524C // 'GURL'
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        let ev = NSAppleEventDescriptor.appleEvent(withEventClass: gurl, eventID: gurl, targetDescriptor: target,
                                                   returnID: AEReturnID(kAutoGenerateReturnID),
                                                   transactionID: AETransactionID(kAnyTransactionID))
        ev.setParam(NSAppleEventDescriptor(string: url), forKeyword: AEKeyword(keyDirectObject))
        guard let desc = ev.aeDesc else { return false }
        return AESendMessage(desc, nil, AESendMode(kAENoReply), kAEDefaultTimeout) == noErr
    }

    /// Starts a profile's Claude instance if it isn't running; returns its pid.
    public static func ensureRunning(_ profile: Profile, timeout: TimeInterval = 25) -> Int32? {
        if let pid = ClaudeProcesses.pid(for: profile, in: ClaudeProcesses.list()) { return pid }
        if profile.isDefault {
            Shell.run("/usr/bin/open", ["-a", "Claude"])
        } else if let launcher = profile.launcherApp {
            Shell.run("/usr/bin/open", [launcher.path])   // the user's own launcher applet
        } else {
            Shell.run("/usr/bin/open", ["-n", "-a", "Claude", "--args", "--user-data-dir=\(profile.dataDir.path)"])
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            usleep(1_000_000)
            if let pid = ClaudeProcesses.pid(for: profile, in: ClaudeProcesses.list()) {
                usleep(6_000_000) // let the window finish loading
                return pid
            }
        }
        return nil
    }

    /// Brings the session to the front in its own profile window (used by "open" buttons).
    public static func reveal(sessionId: String, profile: Profile) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let pid = ensureRunning(profile) else { return }
            NSRunningApplication(processIdentifier: pid)?.activate()
            _ = openSession(sessionId, pid: pid)
        }
    }
}

// MARK: - UI mode

public enum UIRetry {
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    public static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Asks for Accessibility and for permission to send Apple events to Claude, so the
    /// prompts appear while the user is around rather than at 5am. Returns (ax, automation).
    @discardableResult
    public static func preflight(pid: Int32?, ask: Bool = true) -> (Bool, Bool) {
        if ask && !isTrusted { requestTrust() }
        var automation = false
        if let pid {
            let target = NSAppleEventDescriptor(processIdentifier: pid)
            if let desc = target.aeDesc {
                automation = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask) == noErr
            }
        }
        return (isTrusted, automation)
    }

    /// Dry run: opens the session in its window and looks for the composer without typing.
    public static func probe(session: SessionInfo, profile: Profile) -> String {
        guard let pid = DesktopLink.ensureRunning(profile) else { return "Couldn't start the \(profile.name) window" }
        let (ax, ae) = preflight(pid: pid)
        guard ax else { return "Accessibility not granted for this app yet" }
        guard ae else { return "Automation (Apple events to Claude) not granted yet" }
        NSRunningApplication(processIdentifier: pid)?.activate()
        guard DesktopLink.openSession(session.id, pid: pid) else { return "Claude refused the open-session event" }
        usleep(3_000_000)
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        usleep(300_000)
        guard let composer = findComposer(axApp) else { return "Opened the chat, but couldn't find the message box" }
        let value = (attr(composer, kAXValueAttribute) as? String) ?? ""
        return "OK: opened “\(session.title)” in pid \(pid); message box found (\(value.isEmpty ? "empty" : "has a draft"))"
    }

    static func send(message: String, session: SessionInfo, profile: Profile) -> Result<String, RetryError> {
        UILock.run { sendLocked(message: message, session: session, profile: profile) }
    }

    /// Types `message` into the chat in its desktop window (fallback for remote replies without a CLI token).
    public static func type(message: String, session: SessionInfo, profile: Profile) -> Result<String, RetryError> {
        send(message: message, session: session, profile: profile)
    }

    private static func sendLocked(message: String, session: SessionInfo, profile: Profile) -> Result<String, RetryError> {
        guard isTrusted else {
            requestTrust()
            return .failure(RetryError(message: "Waiting for Accessibility permission", blocked: true))
        }
        guard let pid = DesktopLink.ensureRunning(profile) else {
            return .failure(RetryError(message: "Couldn't start the \(profile.name) Claude window"))
        }
        let previous = NSWorkspace.shared.frontmostApplication
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return .failure(RetryError(message: "Claude process \(pid) went away"))
        }
        app.activate()
        guard DesktopLink.openSession(session.id, pid: pid) else {
            return .failure(RetryError(message: "Waiting for Automation permission (Apple events to Claude)", blocked: true))
        }
        usleep(3_000_000)

        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        usleep(300_000)
        if let composer = findComposer(ax) {
            if let value = attr(composer, kAXValueAttribute) as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .failure(RetryError(message: "The chat has an unsent draft; left it alone", permanent: true))
            }
            AXUIElementSetAttributeValue(composer, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            usleep(200_000)
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            return .failure(RetryError(message: "Couldn't bring the \(profile.name) window to the front"))
        }
        type(message, pid: pid)
        usleep(250_000)
        key(36, pid: pid) // Return
        usleep(800_000)
        if let previous, previous.processIdentifier != pid, previous.bundleIdentifier != Bundle.main.bundleIdentifier {
            previous.activate()
        }
        return .success("pid \(pid)")
    }

    static func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    /// The chat composer: the lowest editable text area in the focused window.
    static func findComposer(_ app: AXUIElement) -> AXUIElement? {
        guard let win = attr(app, kAXFocusedWindowAttribute) ?? (attr(app, kAXWindowsAttribute) as? [AnyObject])?.first
        else { return nil }
        var queue: [(AXUIElement, Int)] = [(win as! AXUIElement, 0)]
        var best: (AXUIElement, CGFloat)?
        var visited = 0
        while !queue.isEmpty, visited < 6000 {
            let (el, depth) = queue.removeFirst()
            visited += 1
            let role = attr(el, kAXRoleAttribute) as? String
            if role == kAXTextAreaRole as String || role == kAXTextFieldRole as String {
                var y: CGFloat = 0
                if let posVal = attr(el, kAXPositionAttribute) {
                    var p = CGPoint.zero
                    AXValueGetValue(posVal as! AXValue, .cgPoint, &p)
                    y = p.y
                }
                if best == nil || y > best!.1 { best = (el, y) }
            }
            if depth < 40, let kids = attr(el, kAXChildrenAttribute) as? [AnyObject] {
                for k in kids { queue.append((k as! AXUIElement, depth + 1)) }
            }
        }
        return best?.0
    }

    static func type(_ text: String, pid: Int32) {
        let src = CGEventSource(stateID: .hidSystemState)
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 16, units.count)])
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
                e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                e?.postToPid(pid)
            }
            usleep(30_000)
            i += 16
        }
    }

    static func key(_ code: CGKeyCode, pid: Int32) {
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)?.postToPid(pid)
        CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)?.postToPid(pid)
    }
}

// MARK: - CLI mode

public enum CLIRetry {
    /// The CLI bundled with that profile's desktop app, else `claude` on the login PATH.
    public static func binary(for profile: Profile) -> String? {
        let fm = FileManager.default
        let root = profile.dataDir.appendingPathComponent("claude-code")
        let versions = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0.first?.isNumber == true }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for v in versions {
            let p = root.appendingPathComponent(v).appendingPathComponent("claude.app/Contents/MacOS/claude").path
            if fm.isExecutableFile(atPath: p) { return p }
        }
        if let out = Shell.run("/bin/zsh", ["-lc", "command -v claude"])?.out
            .trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty, fm.isExecutableFile(atPath: out) {
            return out
        }
        return nil
    }

    static func permissionArgs(_ mode: String?) -> [String] {
        switch mode {
        case "acceptEdits", "plan", "auto", "default": return ["--permission-mode", mode!]
        case "bypassPermissions": return ["--permission-mode", "bypassPermissions", "--allow-dangerously-skip-permissions"]
        default: return []
        }
    }

    static func send(message: String, session: SessionInfo, profile: Profile,
                     extraArgs: [String]) -> Result<String, RetryError> {
        guard let cli = session.cliSessionId else {
            return .failure(RetryError(message: "Session has no CLI id", permanent: true))
        }
        guard let token = TokenStore.get(profile.id) else {
            return .failure(RetryError(message: "No CLI token for \(profile.name). Run: claude-watch set-token \(profile.id)",
                                       permanent: true))
        }
        guard let bin = binary(for: profile) else {
            return .failure(RetryError(message: "claude CLI not found", permanent: true))
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["--resume", cli, "-p", message, "--output-format", "json"]
            + (extraArgs.isEmpty ? permissionArgs(session.permissionMode) : extraArgs)
        if FileManager.default.fileExists(atPath: session.cwd) {
            p.currentDirectoryURL = URL(fileURLWithPath: session.cwd)
        }
        var env = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("CLAUDE_CODE_") && $0.key != "ANTHROPIC_API_KEY" && $0.key != "CLAUDECODE"
        }
        env["CLAUDE_CODE_OAUTH_TOKEN"] = token
        p.environment = env
        let stamp = Int(Date().timeIntervalSince1970)
        let logURL = Paths.logs.appendingPathComponent("\(session.id)-\(stamp).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: logURL) { p.standardOutput = h; p.standardError = h }
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch {
            return .failure(RetryError(message: "Couldn't start claude: \(error.localizedDescription)"))
        }
        return .success("pid \(p.processIdentifier), log \(logURL.lastPathComponent)")
    }
}
