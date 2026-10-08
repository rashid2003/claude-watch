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
    public static func newChat(profile: Profile, cwd: String, prompt: String) -> Result<String, RetryError> {
        UILock.run {
            guard UIRetry.isTrusted else {
                UIRetry.requestTrust()
                return .failure(RetryError(message: "ClaudeWatch needs Accessibility permission", blocked: true))
            }
            guard FileManager.default.fileExists(atPath: cwd) else {
                return .failure(RetryError(message: "No such folder on the Mac: \(cwd)", permanent: true))
            }
            guard let pid = DesktopLink.ensureRunning(profile) else {
                return .failure(RetryError(message: "Couldn't start the \(profile.name) Claude window"))
            }
            let previous = NSWorkspace.shared.frontmostApplication
            NSRunningApplication(processIdentifier: pid)?.activate()
            guard DesktopLink.sendGetURL(newChatURL(cwd: cwd, prompt: prompt), pid: pid) else {
                return .failure(RetryError(message: "Waiting for Automation permission (Apple events to Claude)", blocked: true))
            }
            usleep(4_000_000)
            let ax = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            usleep(300_000)
            guard let composer = UIRetry.findComposer(ax) else {
                return .failure(RetryError(message: "Opened a new chat but couldn't find its message box"))
            }
            AXUIElementSetAttributeValue(composer, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            usleep(200_000)
            let value = (UIRetry.attr(composer, kAXValueAttribute) as? String) ?? ""
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { UIRetry.type(prompt, pid: pid) }
            usleep(250_000)
            UIRetry.key(36, pid: pid)   // Return
            usleep(800_000)
            restoreFocus(previous, pid)
            return .success("Started in \(profile.name)")
        }
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
