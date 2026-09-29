import AppKit
import Foundation

/// Quits and reopens profile windows around a chat move.
public enum WindowControl {
    /// Asks each running window to quit (like Cmd+Q) and waits for it to exit.
    public static func quit(_ profiles: [Profile], timeout: TimeInterval = 20) -> (quit: [Profile], stuck: [Profile]) {
        let instances = ClaudeProcesses.list()
        let running = profiles.compactMap { p in ClaudeProcesses.pid(for: p, in: instances).map { (p, $0) } }
        // A window that refuses the request is stuck right away; only wait for the ones that accepted.
        let targets = running.filter { NSRunningApplication(processIdentifier: $0.1)?.terminate() ?? !isAlive($0.1) }
        let refused = running.filter { r in !targets.contains { $0.1 == r.1 } }.map(\.0)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, targets.contains(where: { isAlive($0.1) }) { usleep(250_000) }
        return (targets.filter { !isAlive($0.1) }.map(\.0), refused + targets.filter { isAlive($0.1) }.map(\.0))
    }

    static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    /// Opens each profile through its launcher (see `DesktopLink.ensureRunning`).
    public static func relaunch(_ profiles: [Profile]) {
        for p in profiles { _ = DesktopLink.ensureRunning(p) }
    }
}
