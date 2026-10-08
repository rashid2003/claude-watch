import AppKit
import ApplicationServices
import Foundation

/// Serialises everything that drives a desktop window (retries, remote actions): two at once would
/// type into the wrong place.
public enum UILock {
    private static let lock = NSRecursiveLock()
    public static func run<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    /// Runs `body` only if nothing else is driving a window right now.
    public static func tryRun<T>(_ body: () -> T) -> T? {
        guard lock.try() else { return nil }
        defer { lock.unlock() }
        return body()
    }
}

/// Remote actions performed in a profile's own Claude window.
public enum DesktopActions {
    // MARK: Public actions

    /// Presses the prompt's Allow / Always / Deny button in the chat's window. `dryRun` presses nothing
    /// and reports the buttons it can see.
    public static func answer(decision: PromptDecision, session: SessionInfo, profile: Profile,
                              dryRun: Bool = false) -> Result<String, RetryError> {
        UILock.run {
            withChat(session, profile) { pid, win in
                let buttons = buttons(in: win)
                if dryRun {
                    return .success("Buttons: " + buttons.map { "“\($0.title)”" }.joined(separator: ", "))
                }
                guard let i = matchButton(buttons.map { ($0.title, $0.y) }, for: decision) else {
                    return .failure(RetryError(message: "Couldn't find the \(label(decision)) button in the \(profile.name) window",
                                               permanent: true))
                }
                guard AXUIElementPerformAction(buttons[i].el, kAXPressAction as CFString) == .success else {
                    return .failure(RetryError(message: "Couldn't press “\(buttons[i].title)”"))
                }
                return .success("Pressed “\(buttons[i].title)”")
            }
        }
    }

    /// Interrupts a running turn: presses a Stop button if there is one, otherwise sends Esc.
    public static func stop(session: SessionInfo, profile: Profile) -> Result<String, RetryError> {
        UILock.run {
            withChat(session, profile) { pid, win in
                if let b = buttons(in: win).first(where: { ["stop", "interrupt", "stop generating"].contains($0.title.lowercased()) }),
                   AXUIElementPerformAction(b.el, kAXPressAction as CFString) == .success {
                    return .success("Pressed “\(b.title)”")
                }
                UIRetry.key(53, pid: pid)   // Esc
                return .success("Sent Esc")
            }
        }
    }

    /// Opens a new Code chat in `cwd` in the profile's window with `prompt`, and sends it.
    ///
    /// The desktop asks "Trust this workspace?" for every folder that arrives in a link, trusted or not.
    /// The prompt is accepted here only when it names this very folder, and only when Claude Code
    /// already trusts it or the phone explicitly asked to trust it (`allowTrust`).
    public static func newChat(profile: Profile, cwd: String, prompt: String, allowTrust: Bool = false) -> Result<String, RetryError> {
        UILock.run {
            guard UIRetry.isTrusted else {
                UIRetry.requestTrust()
                return .failure(RetryError(message: "ClaudeWatch needs Accessibility permission", blocked: true))
            }
            guard FileManager.default.fileExists(atPath: cwd) else {
                return .failure(RetryError(message: "No such folder on the Mac: \(cwd)", permanent: true))
            }
            guard allowTrust || WorkspaceTrust.isTrusted(cwd) else {
                return .failure(RetryError(message: untrustedMessage, permanent: true))
            }
            guard let pid = DesktopLink.ensureRunning(profile) else {
                return .failure(RetryError(message: "Couldn't start the \(profile.name) Claude window"))
            }
            let before = Set(SessionIndex().sessions(for: profile).map(\.id))
            let previous = NSWorkspace.shared.frontmostApplication
            defer { restoreFocus(previous, pid) }
            NSRunningApplication(processIdentifier: pid)?.activate()
            guard DesktopLink.sendGetURL(newChatURL(cwd: cwd, prompt: prompt), pid: pid) else {
                return .failure(RetryError(message: "Waiting for Automation permission (Apple events to Claude)", blocked: true))
            }
            let ax = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)

            // Wait for the folder prompt; a desktop that doesn't ask goes on once its composer has the prompt.
            let shown = linkFolder(cwd)
            let start = Date()
            var accepted = false
            while Date().timeIntervalSince(start) < 12 {
                usleep(400_000)
                if let (button, texts) = trustPrompt(ax) {
                    guard promptNames(shown, texts) else {
                        return .failure(RetryError(message: "The \(profile.name) window is asking to trust a different folder. Answer it on the Mac.",
                                                   permanent: true))
                    }
                    guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
                        return .failure(RetryError(message: "Couldn't confirm the folder in the \(profile.name) window"))
                    }
                    accepted = true
                    usleep(900_000)
                    break
                }
                if Date().timeIntervalSince(start) > 8, let c = UIRetry.findComposer(ax),
                   startsLike(UIRetry.attr(c, kAXValueAttribute) as? String, prompt) { break }
            }
            if accepted, trustPrompt(ax) != nil {
                return .failure(RetryError(message: "The folder prompt is still showing in the \(profile.name) window"))
            }

            guard let composer = UIRetry.findComposer(ax) else {
                return .failure(RetryError(message: "Opened a new chat but couldn't find its message box"))
            }
            AXUIElementSetAttributeValue(composer, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            usleep(200_000)
            let value = (UIRetry.attr(composer, kAXValueAttribute) as? String) ?? ""
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { UIRetry.type(prompt, pid: pid) }
            usleep(250_000)
            UIRetry.key(36, pid: pid)   // Return

            // Confirm the chat exists before reporting success.
            for _ in 0..<20 {
                usleep(750_000)
                if let s = SessionIndex().sessions(for: profile).first(where: { !before.contains($0.id) }) {
                    return sameFolder(s.cwd, cwd) || sameFolder(s.cwd, shown)
                        ? .success("Started in \(profile.name)")
                        : .success("Started in \(profile.name), in \(s.cwd)")
                }
            }
            return .success("Sent to the \(profile.name) window; the chat hasn't shown up yet")
        }
    }

    public static let untrustedMessage = "Claude Code doesn't trust this folder on the Mac yet."

    /// The desktop opens a folder inside `<repo>/.claude/worktrees/` at the repo itself.
    static func linkFolder(_ cwd: String) -> String {
        let parts = (cwd as NSString).standardizingPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for i in 1..<max(1, parts.count - 2) where parts[i].lowercased() == ".claude" && parts[i + 1].lowercased() == "worktrees" {
            let root = parts[0..<i].joined(separator: "/")
            return root.isEmpty ? "/" : root
        }
        return (cwd as NSString).standardizingPath
    }

    /// The prompt's texts show `folder`: in full, or (very long paths) its start before the ellipsis.
    static func promptNames(_ folder: String, _ texts: [String]) -> Bool {
        let f = WorkspaceTrust.normalize(folder)
        return texts.contains { t in
            let t = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if WorkspaceTrust.normalize(t) == f { return true }
            return f.count > 120 && t.count >= 120 && f.hasPrefix(String(t.prefix(120)))
        }
    }

    static func startsLike(_ value: String?, _ prompt: String) -> Bool {
        let v = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return !v.isEmpty && v.hasPrefix(String(p.prefix(40)))
    }

    static func sameFolder(_ a: String, _ b: String) -> Bool { WorkspaceTrust.normalize(a) == WorkspaceTrust.normalize(b) }

    /// The "Trust workspace" button of an open folder prompt, with the texts in its window.
    private static func trustPrompt(_ ax: AXUIElement) -> (AXUIElement, [String])? {
        for case let win as AXUIElement in (UIRetry.attr(ax, kAXWindowsAttribute) as? [AnyObject]) ?? [] {
            guard let b = buttons(in: win).first(where: { $0.title.trimmingCharacters(in: .whitespaces).lowercased() == "trust workspace" })
            else { continue }
            return (b.el, texts(in: win))
        }
        return nil
    }

    /// `claude://code/new?folder=<cwd>&q=<prompt>` (the desktop app caps the prompt at 14 336 chars).
    public static func newChatURL(cwd: String, prompt: String) -> String {
        var c = URLComponents()
        c.scheme = "claude"; c.host = "code"; c.path = "/new"
        c.queryItems = [URLQueryItem(name: "folder", value: cwd), URLQueryItem(name: "q", value: String(prompt.prefix(14_000))),
                        URLQueryItem(name: "source", value: "claude-watch")]
        // URLSearchParams reads "+" as a space.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.string ?? ""
    }

    // MARK: Matching (pure, tested)

    /// Index of the button to press for a decision: the lowest one on screen whose title matches.
    static func matchButton(_ buttons: [(title: String, y: CGFloat)], for d: PromptDecision) -> Int? {
        func norm(_ s: String) -> String {
            s.lowercased().replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func isAlways(_ t: String) -> Bool {
            t.contains("always") || t.contains("don't ask again") || t.contains("for this session") || t.hasPrefix("allow all")
        }
        func matches(_ raw: String) -> Bool {
            let t = norm(raw)
            switch d {
            case .allowAlways: return isAlways(t) && !t.hasPrefix("don't allow") && !t.hasPrefix("deny")
            case .allow:
                if isAlways(t) || t.hasPrefix("don't") { return false }
                return ["allow", "allow once", "allow this time", "yes", "approve", "accept", "run", "run once"].contains(t)
                    || t.hasPrefix("allow ") || t.hasPrefix("yes,") || t.hasPrefix("yes ")
            case .deny:
                return ["deny", "no", "reject", "decline", "don't allow"].contains(t)
                    || t.hasPrefix("deny ") || t.hasPrefix("no,") || t.hasPrefix("no ") || t.hasPrefix("don't allow")
            }
        }
        return buttons.indices.filter { matches(buttons[$0].title) }.max { buttons[$0].y < buttons[$1].y }
    }

    static func label(_ d: PromptDecision) -> String {
        switch d { case .allow: "Allow"; case .allowAlways: "Always allow"; case .deny: "Deny" }
    }

    // MARK: AX helpers

    struct Button { var el: AXUIElement; var title: String; var y: CGFloat }

    /// Opens the chat in its window, runs `body` with the pid and window, then gives focus back.
    private static func withChat(_ session: SessionInfo, _ profile: Profile,
                                 _ body: (Int32, AXUIElement) -> Result<String, RetryError>) -> Result<String, RetryError> {
        guard UIRetry.isTrusted else {
            UIRetry.requestTrust()
            return .failure(RetryError(message: "ClaudeWatch needs Accessibility permission", blocked: true))
        }
        guard let pid = DesktopLink.ensureRunning(profile) else {
            return .failure(RetryError(message: "Couldn't start the \(profile.name) Claude window"))
        }
        let previous = NSWorkspace.shared.frontmostApplication
        NSRunningApplication(processIdentifier: pid)?.activate()
        guard DesktopLink.openSession(session.id, pid: pid) else {
            return .failure(RetryError(message: "Waiting for Automation permission (Apple events to Claude)", blocked: true))
        }
        usleep(2_500_000)
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        usleep(300_000)
        guard let win = (UIRetry.attr(ax, kAXFocusedWindowAttribute) ?? (UIRetry.attr(ax, kAXWindowsAttribute) as? [AnyObject])?.first)
        else { return .failure(RetryError(message: "Couldn't read the \(profile.name) window")) }
        let r = body(pid, win as! AXUIElement)
        usleep(500_000)
        restoreFocus(previous, pid)
        return r
    }

    private static func restoreFocus(_ previous: NSRunningApplication?, _ pid: Int32) {
        if let previous, previous.processIdentifier != pid, previous.bundleIdentifier != Bundle.main.bundleIdentifier {
            previous.activate()
        }
    }

    /// Static texts (and the full-path tooltips the desktop puts on shortened ones) in a window.
    static func texts(in win: AXUIElement) -> [String] {
        var out: [String] = []
        var queue: [(AXUIElement, Int)] = [(win, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 8000 {
            let (el, depth) = queue.removeFirst()
            visited += 1
            for name in [kAXValueAttribute, kAXTitleAttribute, kAXHelpAttribute, kAXDescriptionAttribute] {
                if let t = UIRetry.attr(el, name) as? String, !t.isEmpty { out.append(t) }
            }
            if depth < 40, let kids = UIRetry.attr(el, kAXChildrenAttribute) as? [AnyObject] {
                for k in kids { queue.append((k as! AXUIElement, depth + 1)) }
            }
        }
        return out
    }

    static func buttons(in win: AXUIElement) -> [Button] {
        var out: [Button] = []
        var queue: [(AXUIElement, Int)] = [(win, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 8000 {
            let (el, depth) = queue.removeFirst()
            visited += 1
            if (UIRetry.attr(el, kAXRoleAttribute) as? String) == kAXButtonRole as String {
                let title = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
                    .lazy.compactMap { UIRetry.attr(el, $0) as? String }.first { !$0.isEmpty } ?? ""
                var y: CGFloat = 0
                if let v = UIRetry.attr(el, kAXPositionAttribute) {
                    var p = CGPoint.zero
                    AXValueGetValue(v as! AXValue, .cgPoint, &p)
                    y = p.y
                }
                if !title.isEmpty { out.append(Button(el: el, title: title, y: y)) }
            }
            if depth < 40, let kids = UIRetry.attr(el, kAXChildrenAttribute) as? [AnyObject] {
                for k in kids { queue.append((k as! AXUIElement, depth + 1)) }
            }
        }
        return out
    }
}
