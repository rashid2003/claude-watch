import Darwin
import Foundation

/// Raw readings of the Mac's memory, swap, load and disk. Cheap: sysctl / Mach calls, no child processes.
public enum SystemProbe {
    /// The kernel's memory-pressure level (what Activity Monitor's pressure graph colours by).
    public static func pressure() -> HealthLevel {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &v, &size, nil, 0) == 0 else { return .ok }
        return v >= 4 ? .critical : v >= 2 ? .warn : .ok
    }

    /// Used = app memory + wired + compressed, as Activity Monitor's "Memory Used".
    public static func memory() -> (total: Int64, used: Int64, compressed: Int64) {
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &size, nil, 0)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return (Int64(total), 0, 0) }
        let page = Int64(getpagesize())
        let app = Int64(stats.internal_page_count) - Int64(stats.purgeable_count)
        let compressed = Int64(stats.compressor_page_count) * page
        let used = (max(0, app) + Int64(stats.wire_count)) * page + compressed
        return (Int64(total), min(used, Int64(total)), compressed)
    }

    public static func swap() -> (used: Int64, total: Int64) {
        var x = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &x, &size, nil, 0) == 0 else { return (0, 0) }
        return (Int64(x.xsu_used), Int64(x.xsu_total))
    }

    public static func load() -> (one: Double, five: Double) {
        var l = [Double](repeating: 0, count: 3)
        guard getloadavg(&l, 3) == 3 else { return (0, 0) }
        return (l[0], l[1])
    }

    /// Free space as Finder counts it (includes purgeable space macOS can reclaim).
    public static func disk() -> (free: Int64, total: Int64) {
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                                         .volumeTotalCapacityKey])
        return (v?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(v?.volumeTotalCapacity ?? 0))
    }
}
