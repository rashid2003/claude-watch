import Darwin
import Foundation

/// One of the user's processes at one moment.
public struct ProcSample: Sendable {
    public var pid: Int32
    public var ppid: Int32
    public var name: String
    public var path: String
    /// Physical footprint, bytes (Activity Monitor's "Memory").
    public var footprint: Int64
    /// User + system CPU time so far, nanoseconds.
    public var cpuNanos: UInt64
    /// The process macOS holds responsible (e.g. Docker for its Virtualization.framework VM); itself when unknown.
    public var responsible: Int32

    public init(pid: Int32, ppid: Int32, name: String, path: String, footprint: Int64, cpuNanos: UInt64, responsible: Int32? = nil) {
        self.pid = pid; self.ppid = ppid; self.name = name; self.path = path; self.footprint = footprint; self.cpuNanos = cpuNanos
        self.responsible = responsible ?? pid
    }
}

/// Lists the user's processes with their memory and CPU % since the previous call.
public final class ProcessScan {
    private var last: [Int32: (cpu: UInt64, at: UInt64)] = [:]
    private let timebase: mach_timebase_info_data_t = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t }()

    public init() {}

    public func sample() -> [(ProcSample, cpu: Double)] {
        let now = DispatchTime.now().uptimeNanoseconds
        var out: [(ProcSample, cpu: Double)] = []
        var seen: [Int32: (cpu: UInt64, at: UInt64)] = [:]
        for p in ProcessTree.all() {
            guard let s = Self.read(p.pid, ppid: p.ppid, timebase: timebase) else { continue }
            var pct = 0.0
            if let prev = last[p.pid], now > prev.at, s.cpuNanos >= prev.cpu {
                pct = Double(s.cpuNanos - prev.cpu) / Double(now - prev.at) * 100
            }
            seen[p.pid] = (s.cpuNanos, now)
            out.append((s, pct))
        }
        last = seen
        return out
    }

    static func read(_ pid: Int32, ppid: Int32, timebase: mach_timebase_info_data_t) -> ProcSample? {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard ok == 0 else { return nil }
        let path = pidPath(pid)
        let name = path.isEmpty ? procName(pid) : (path as NSString).lastPathComponent
        // On Apple Silicon these are Mach ticks, not nanoseconds.
        let ticks = info.ri_user_time + info.ri_system_time
        let nanos = ticks * UInt64(timebase.numer) / UInt64(max(1, timebase.denom))
        return ProcSample(pid: pid, ppid: ppid, name: name, path: path, footprint: Int64(info.ri_phys_footprint), cpuNanos: nanos,
                          responsible: responsibleFn.map { $0(pid) }.flatMap { $0 > 0 ? $0 : nil })
    }

    /// Private libquarantine call Activity Monitor uses to attribute XPC services to their app.
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsibleFn: ResponsibleFn? = {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")   // RTLD_DEFAULT
            .map { unsafeBitCast($0, to: ResponsibleFn.self) }
    }()

    static func pidPath(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return "" }
        return String(cString: buf)
    }

    static func procName(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { return "pid \(pid)" }
        return String(cString: buf)
    }
}

/// Folds processes into apps: helpers count toward the outermost .app they live in, each Claude
/// profile is its own row, and everything else is one row per process.
public enum AppGrouper {
    public static func bundle(of path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return path.hasSuffix(".app") ? path : nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    /// Top `limit` by memory plus top `limit` by CPU (those using at least 1%), largest memory first.
    public static func group(_ procs: [(ProcSample, cpu: Double)], appPid: (String) -> Int32?, appName: (String) -> String?,
                             claudeNames: [Int32: String], guardFn: (ProcSample) -> Bool, limit: Int = 12) -> [AppUsage] {
        let byPid = Dictionary(procs.map { ($0.0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        func claudeRoot(_ p: ProcSample) -> Int32? {
            var cur: Int32? = p.pid
            for _ in 0..<32 {
                guard let c = cur else { return nil }
                if claudeNames[c] != nil { return c }
                cur = byPid[c].map(\.0.ppid).flatMap { $0 > 1 ? $0 : nil }
            }
            return nil
        }

        var groups: [String: [(ProcSample, cpu: Double)]] = [:]
        for e in procs {
            // A process outside any app counts toward the app macOS holds responsible for it, if that's an app.
            let owner = bundle(of: e.0.path) == nil && e.0.responsible != e.0.pid ? byPid[e.0.responsible]?.0 ?? e.0 : e.0
            let key: String
            if let root = claudeRoot(e.0) ?? claudeRoot(owner) { key = "claude:\(root)" }
            else if let b = bundle(of: e.0.path) ?? bundle(of: owner.path) { key = b }
            else { key = "pid:\(e.0.pid)" }
            groups[key, default: []].append(e)
        }

        let rows: [AppUsage] = groups.map { key, members in
            let sorted = members.sorted { $0.0.footprint > $1.0.footprint }
            let name: String
            let main: Int32
            let canQuit: Bool
            if key.hasPrefix("claude:"), let root = Int32(key.dropFirst(7)) {
                name = "Claude · " + (claudeNames[root] ?? "?")
                main = root
                canQuit = true
            } else if key.hasPrefix("pid:") {
                name = sorted[0].0.name
                main = sorted[0].0.pid
                canQuit = false
            } else {
                // Claude Code sessions run from a bare "claude.app" inside the desktop app's data folder.
                name = appName(key) ?? (key.contains("/claude-code/") ? "Claude Code"
                    : ((key as NSString).lastPathComponent as NSString).deletingPathExtension)
                main = appPid(key) ?? members.map(\.0.pid).min()!
                canQuit = true   // NSRunningApplication.terminate, else a polite SIGTERM to the main process
            }
            return AppUsage(id: key, name: name, rss: members.reduce(0) { $0 + $1.0.footprint },
                            cpu: members.reduce(0) { $0 + $1.cpu }, processes: members.count,
                            pids: sorted.prefix(20).map(\.0.pid), mainPid: main, canQuit: canQuit,
                            canKill: byPid[main].map { guardFn($0.0) } ?? false)
        }

        let byMem = rows.sorted { $0.rss > $1.rss }.prefix(limit)
        let byCPU = rows.filter { $0.cpu >= 1 }.sorted { $0.cpu > $1.cpu }.prefix(limit)
        var ids = Set<String>()
        return (Array(byMem) + Array(byCPU)).filter { ids.insert($0.id).inserted }.sorted { $0.rss > $1.rss }
    }
}

/// What may be force-killed: the user's own processes, never core macOS ones or Session Watch itself.
public enum KillGuard {
    public static let protectedNames: Set<String> = ["launchd", "WindowServer", "kernel_task", "loginwindow", "Dock",
                                                     "Finder", "SystemUIServer", "ControlCenter"]

    public static func allows(pid: Int32, name: String, ownerUid: uid_t, myUid: uid_t = getuid(), selfPid: Int32 = getpid()) -> Bool {
        pid > 1 && pid != selfPid && ownerUid == myUid && !protectedNames.contains(name)
    }

    /// Checks the live process; the message says why not.
    public static func allowsLive(pid: Int32) -> (ok: Bool, message: String) {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return (false, "That process isn't running any more") }
        let path = ProcessScan.pidPath(pid)
        let name = path.isEmpty ? ProcessScan.procName(pid) : (path as NSString).lastPathComponent
        if allows(pid: pid, name: name, ownerUid: info.kp_eproc.e_ucred.cr_uid) { return (true, name) }
        return (false, "Session Watch won't kill \(name) (pid \(pid))")
    }
}
