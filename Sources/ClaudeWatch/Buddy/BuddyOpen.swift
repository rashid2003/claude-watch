import AppKit
import WatchCore

/// Brings the chat a buddy click points at to the front, in its desktop window or its terminal.
enum BuddyOpen {
    static func open(_ chat: BuddyChat, model: WatchModel) {
        if chat.isTerminal {
            guard let profile = model.profile(chat.profileId) else { model.showMain(.chats); return }
            let dir = profile.dataDir, ids = Set(chat.sessionIds)
            DispatchQueue.global(qos: .userInitiated).async {
                if !focusTerminal(sessionIds: ids, dataDir: dir) {
                    DispatchQueue.main.async { model.showMain(.chats) }
                }
            }
        } else {
            model.open(sessionId: chat.id, profileId: chat.profileId)
        }
    }

    // MARK: Terminal

    /// The pid of the live `claude` holding one of these chats open.
    static func pid(sessionIds: Set<String>, dataDir: URL) -> Int32? {
        let dir = dataDir.appendingPathComponent("sessions")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var best: (pid: Int32, at: Double)?
        for f in files where f.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(f)),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (o["pid"] as? NSNumber)?.int32Value, pid > 0,
                  let sid = o["sessionId"] as? String, sessionIds.contains(sid),
                  kill(pid, 0) == 0 else { continue }
            let at = (o["updatedAt"] as? NSNumber)?.doubleValue ?? 0
            if best == nil || at > best!.at { best = (pid, at) }
        }
        return best?.pid
    }

    /// Selects the tab/pane showing `pid`'s tty, then raises its app. Returns false if nothing was found.
    static func focusTerminal(sessionIds: Set<String>, dataDir: URL) -> Bool {
        guard let pid = pid(sessionIds: sessionIds, dataDir: dataDir) else { return false }
        let tty = TerminalInjector.run("/bin/ps", ["-o", "tty=", "-p", String(pid)]).out
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !tty.isEmpty, tty != "??", tty != "?" {
            let dev = tty.hasPrefix("/dev/") ? tty : "/dev/" + tty
            if let tmux = TerminalInjector.findTmux() {
                let r = TerminalInjector.run(tmux, ["list-panes", "-a", "-F", "#{pane_tty} #{pane_id}"])
                if let pane = r.out.split(separator: "\n").map({ $0.split(separator: " ") })
                    .first(where: { $0.count == 2 && $0[0] == Substring(dev) })?[1] {
                    _ = TerminalInjector.run(tmux, ["select-window", "-t", String(pane)])
                    _ = TerminalInjector.run(tmux, ["select-pane", "-t", String(pane)])
                    activateOwner(of: pid)
                    return true
                }
            }
            for (process, script) in [("iTerm2", iTermScript), ("Terminal", terminalScript)] where TerminalInjector.isRunning(process) {
                let r = TerminalInjector.run("/usr/bin/osascript", ["-e", script, dev])
                if r.status == 0, r.out.contains("ok") { return true }
            }
        }
        return activateOwner(of: pid)
    }

    /// Raises the GUI app (Ghostty, Warp, VS Code…) that is an ancestor of `pid`.
    @discardableResult
    static func activateOwner(of pid: Int32) -> Bool {
        let parents = Dictionary(ProcessTree.all().map { ($0.pid, $0.ppid) }, uniquingKeysWith: { a, _ in a })
        var p = pid, hops = 0
        while p > 1, hops < 30 {
            if let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular {
                DispatchQueue.main.async { app.activate(options: [.activateAllWindows]) }
                return true
            }
            p = parents[p] ?? 0; hops += 1
        }
        return false
    }

    static let iTermScript = """
    on run argv
      set theTTY to item 1 of argv
      tell application "iTerm2"
        repeat with w in windows
          repeat with t in tabs of w
            repeat with s in sessions of t
              if tty of s is theTTY then
                tell w to select
                tell t to select
                tell s to select
                activate
                return "ok"
              end if
            end repeat
          end repeat
        end repeat
      end tell
      return "none"
    end run
    """

    static let terminalScript = """
    on run argv
      set theTTY to item 1 of argv
      tell application "Terminal"
        repeat with w in windows
          repeat with t in tabs of w
            if tty of t is theTTY then
              set selected tab of w to t
              set index of w to 1
              activate
              return "ok"
            end if
          end repeat
        end repeat
      end tell
      return "none"
    end run
    """
}
