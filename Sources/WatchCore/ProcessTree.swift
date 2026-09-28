import Darwin
import Foundation

public enum ProcessTree {
    public struct Proc: Sendable { public var pid: Int32; public var ppid: Int32; public var startedAt: Date }

    /// Every process of this user, with its parent and start time.
    public static func all() -> [Proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
        size = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride).compactMap { k in
            guard k.kp_proc.p_pid > 0 else { return nil }
            let tv = k.kp_proc.p_un.__p_starttime
            return Proc(pid: k.kp_proc.p_pid, ppid: k.kp_eproc.e_ppid,
                        startedAt: Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6))
        }
    }

    /// Start times of the direct children of each pid in `parents`.
    public static func childStarts(of parents: Set<Int32>, in procs: [Proc] = all()) -> [Int32: [Date]] {
        var out: [Int32: [Date]] = [:]
        for p in procs where parents.contains(p.ppid) { out[p.ppid, default: []].append(p.startedAt) }
        return out
    }
}
