import AppKit
import ApplicationServices
import Foundation

/// Reads the unsent text in a Claude desktop window's composer for the chat that window shows.
/// Read-only: it never focuses, activates or types into anything. Call it from one queue.
public final class DesktopDraftReader: @unchecked Sendable {
    struct Win {
        var el: AXUIElement
        var webAreas: [AXUIElement]
        var composer: AXUIElement?
    }

    private var pids: [String: (pid: Int32, at: Date)] = [:]      // profile id -> pid
    private var windows: [Int32: (wins: [Win], at: Date)] = [:]
    private var exposed = Set<Int32>()                            // pids with their web content exposed to AX
    /// How long a found pid / window tree is reused before looking again.
    static let pidTTL: TimeInterval = 30
    static let treeTTL: TimeInterval = 15

    public init() {}

    /// The composer text of a window showing `session`; nil when no window shows it or it can't be read
    /// (no Accessibility permission, window not running, or another action is driving the window).
    public func read(session: SessionInfo, profile: Profile, now: Date = Date()) -> String? {
        guard UIRetry.isTrusted, let pid = pid(for: profile, now) else { return nil }
        return UILock.tryRun { () -> String? in
            switch value(tree(pid, now, rescan: false), session) {
            case .text(let t): return t
            case .notShown: return nil
            case .stale:
                // The window shows the chat but its composer went away (re-rendered, window reopened): look again,
                // at most every few seconds.
                guard windows[pid].map({ now.timeIntervalSince($0.at) >= 5 }) ?? true else { return nil }
                if case .text(let t) = value(tree(pid, now, rescan: true), session) { return t }
                return nil
            }
        } ?? nil
    }

    private enum Found { case text(String), notShown, stale }

    private func value(_ wins: [Win], _ s: SessionInfo) -> Found {
        var found = Found.notShown
        for w in wins where Self.shows(chatId: s.id, cliId: s.cliSessionId, title: s.title, urls: w.webAreas.compactMap(Self.url),
                                       windowTitle: UIRetry.attr(w.el, kAXTitleAttribute) as? String) {
            var v: CFTypeRef?
            if let c = w.composer, AXUIElementCopyAttributeValue(c, kAXValueAttribute as CFString, &v) == .success {
                return .text(v as? String ?? "")
            }
            found = .stale
        }
        return found
    }

    /// Forgets cached windows (e.g. when no phone is watching any more).
    public func reset() {
        windows = [:]
        pids = [:]
    }

    // MARK: Matching (pure, tested)

    /// Whether a window shows a chat: its web view's URL names the chat, or else its title is the chat's.
    static func shows(chatId: String, cliId: String?, title: String, urls: [String], windowTitle: String?) -> Bool {
        let ids = [chatId, cliId ?? ""].filter { $0.count > 6 }
        if urls.contains(where: { u in ids.contains { u.contains($0) } }) { return true }
        if urls.contains(where: { $0.contains("local_") }) { return false }   // it names some other chat
        let t = title.trimmingCharacters(in: .whitespaces)
        guard let w = windowTitle?.trimmingCharacters(in: .whitespaces), !w.isEmpty, t.count >= 3, t != "Claude" else { return false }
        return w == t || w.hasPrefix(t + " ") || w.hasSuffix(" " + t)
    }

    // MARK: AX

    private func pid(for profile: Profile, _ now: Date) -> Int32? {
        if let c = pids[profile.id], now.timeIntervalSince(c.at) < Self.pidTTL, c.pid == 0 || kill(c.pid, 0) == 0 {
            return c.pid == 0 ? nil : c.pid   // 0: not running when last looked
        }
        let pid = ClaudeProcesses.pid(for: profile, in: ClaudeProcesses.list())
        pids[profile.id] = (pid ?? 0, now)
        return pid
    }

    private func tree(_ pid: Int32, _ now: Date, rescan: Bool) -> [Win] {
        if !rescan, let c = windows[pid], now.timeIntervalSince(c.at) < Self.treeTTL { return c.wins }
        let app = AXUIElementCreateApplication(pid)
        if exposed.insert(pid).inserted {
            // Electron only builds its web content's AX tree when asked (the retries and actions do the same).
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        let wins = ((UIRetry.attr(app, kAXWindowsAttribute) as? [AnyObject]) ?? []).map { w -> Win in
            let el = w as! AXUIElement
            return Win(el: el, webAreas: Self.webAreas(in: el), composer: UIRetry.composer(in: el))
        }
        windows[pid] = (wins, now)
        return wins
    }

    static func webAreas(in win: AXUIElement) -> [AXUIElement] {
        var out: [AXUIElement] = []
        var queue: [(AXUIElement, Int)] = [(win, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 400 {
            let (el, depth) = queue.removeFirst()
            visited += 1
            if (UIRetry.attr(el, kAXRoleAttribute) as? String) == "AXWebArea" { out.append(el); continue }
            if depth < 12, let kids = UIRetry.attr(el, kAXChildrenAttribute) as? [AnyObject] {
                for k in kids { queue.append((k as! AXUIElement, depth + 1)) }
            }
        }
        return out
    }

    static func url(_ el: AXUIElement) -> String? {
        guard let v = UIRetry.attr(el, kAXURLAttribute) else { return nil }
        return (v as? URL)?.absoluteString ?? (v as? String)
    }
}
