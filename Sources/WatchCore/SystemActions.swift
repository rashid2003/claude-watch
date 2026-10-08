import AppKit
import Foundation

/// Something the user (or auto-act) asked for to relieve the Mac.
public enum SystemAction: Sendable, Equatable {
    /// `AppUsage.id`: a bundle path, "claude:<pid>", or a plain process name (from the auto-act list).
    case quitApp(String)
    case kill(Int32)
    case closeIdleClaude
    case clean([String])
}

/// Carries out a `SystemAction`. Shared by the bridge, the Mac window and auto-act. Blocking (up to ~30 s).
public enum SystemActions {
    public static func run(_ a: SystemAction, snapshot: Snapshot?, apps: [AppUsage], force: Bool = false) -> (ok: Bool, message: String) {
        switch a {
        case .quitApp(let id): return quit(id, apps: apps, force: force)
        case .kill(let pid): return kill(pid)
        case .closeIdleClaude: return closeIdleClaude(snapshot)
        case .clean(let ids):
            let r = DiskCleaner().clean(ids)
            let msg = "Freed \(SystemText.gb(r.freed))" + (r.errors.isEmpty ? "" : " · " + r.errors.joined(separator: " · "))
            return (r.errors.isEmpty, msg)
        }
    }

    static func displayName(_ id: String, _ apps: [AppUsage]) -> String {
        apps.first { $0.id == id }?.name ?? ((id as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    static func quit(_ id: String, apps: [AppUsage], force: Bool) -> (ok: Bool, message: String) {
        let name = displayName(id, apps)
        var pids: [Int32] = []
        if id.hasPrefix("claude:"), let pid = Int32(id.dropFirst(7)) {
            if NSRunningApplication(processIdentifier: pid)?.terminate() == true { pids = [pid] }
        } else if id.hasSuffix(".app") {
            for app in NSWorkspace.shared.runningApplications where app.bundleURL?.standardizedFileURL.path == id {
                app.terminate()
                pids.append(app.processIdentifier)
            }
        } else if !id.hasPrefix("pid:") {
            // A loose process by name (auto-act list): SIGTERM each of the user's own copies.
            for p in ProcessTree.all() {
                let path = ProcessScan.pidPath(p.pid)
                let n = path.isEmpty ? ProcessScan.procName(p.pid) : (path as NSString).lastPathComponent
                guard n == id, KillGuard.allowsLive(pid: p.pid).ok else { continue }
                if Darwin.kill(p.pid, SIGTERM) == 0 { pids.append(p.pid) }
            }
        }
        guard !pids.isEmpty else { return (false, "\(name) isn't running") }
        let deadline = Date().addingTimeInterval(force ? 30 : 10)
        while Date() < deadline, pids.contains(where: alive) { usleep(250_000) }
        let left = pids.filter(alive)
        if left.isEmpty { return (true, "Quit \(name)") }
        if force {
            for p in left where KillGuard.allowsLive(pid: p).ok { Darwin.kill(p, SIGKILL) }
            usleep(500_000)
            return left.contains(where: alive) ? (false, "\(name) is still running") : (true, "Force-quit \(name)")
        }
        return (false, "\(name) is still running (it may be asking to save)")
    }

    static func kill(_ pid: Int32) -> (ok: Bool, message: String) {
        let check = KillGuard.allowsLive(pid: pid)
        guard check.ok else { return (false, check.message) }
        guard Darwin.kill(pid, SIGKILL) == 0 else { return (false, "Couldn't kill \(check.message) (pid \(pid))") }
        for _ in 0..<20 where alive(pid) { usleep(100_000) }
        return (true, "Killed \(check.message) (pid \(pid))")
    }

    /// Quits Claude desktop profiles that have no chat working or waiting on you.
    static func closeIdleClaude(_ snapshot: Snapshot?) -> (ok: Bool, message: String) {
        guard let s = snapshot else { return (false, "No data yet") }
        let instances = ClaudeProcesses.list()
        let running = s.profiles.filter { ClaudeProcesses.pid(for: $0, in: instances) != nil }
        let busy = Set(s.accounts.flatMap(\.sessions).filter { $0.activity == .working || $0.activity == .waiting }
            .map(\.info.profileId))
        let idle = running.filter { !busy.contains($0.id) }
        let kept = running.filter { busy.contains($0.id) }.map(\.name)
        guard !idle.isEmpty else {
            return (true, kept.isEmpty ? "No Claude windows are open" : "No idle Claude windows · kept \(kept.joined(separator: ", ")) (busy)")
        }
        let (quit, stuck) = WindowControl.quit(idle)
        var parts: [String] = []
        if !quit.isEmpty { parts.append("Closed " + quit.map(\.name).joined(separator: ", ")) }
        if !kept.isEmpty { parts.append("kept " + kept.joined(separator: ", ") + " (busy)") }
        if !stuck.isEmpty { parts.append("couldn't close " + stuck.map(\.name).joined(separator: ", ")) }
        return (stuck.isEmpty, parts.joined(separator: " · "))
    }

    static func alive(_ pid: Int32) -> Bool { Darwin.kill(pid, 0) == 0 }
}
