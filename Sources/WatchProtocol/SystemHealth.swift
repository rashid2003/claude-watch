import Foundation

// MARK: - System health (the Mac's memory, swap, CPU, thermal and disk)

public enum HealthLevel: String, Codable, Sendable, Comparable, CaseIterable {
    case ok, warn, critical

    var rank: Int {
        switch self { case .ok: 0; case .warn: 1; case .critical: 2 }
    }

    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

/// One point of the 30-minute trend.
public struct HealthPoint: Codable, Hashable, Sendable {
    public var at: Date
    public var memUsed: Int64
    public var swapUsed: Int64
    public var diskFree: Int64
    public var load1: Double

    public init(at: Date, memUsed: Int64, swapUsed: Int64, diskFree: Int64, load1: Double) {
        self.at = at; self.memUsed = memUsed; self.swapUsed = swapUsed; self.diskFree = diskFree; self.load1 = load1
    }
}

/// One app (its helper processes summed) or one loose process.
public struct AppUsage: Codable, Hashable, Sendable, Identifiable {
    /// Bundle path ("/Applications/Docker.app"), "claude:<pid>" for a Claude profile, or "pid:<pid>".
    public var id: String
    public var name: String
    /// Physical footprint, bytes.
    public var rss: Int64
    /// Percent of one core (can exceed 100).
    public var cpu: Double
    public var processes: Int
    /// Largest first, at most 20.
    public var pids: [Int32]
    /// What Kill acts on.
    public var mainPid: Int32
    public var canQuit: Bool
    public var canKill: Bool

    public init(id: String, name: String, rss: Int64, cpu: Double, processes: Int, pids: [Int32], mainPid: Int32,
                canQuit: Bool, canKill: Bool) {
        self.id = id; self.name = name; self.rss = rss; self.cpu = cpu; self.processes = processes; self.pids = pids
        self.mainPid = mainPid; self.canQuit = canQuit; self.canKill = canKill
    }
}

/// Something "free disk" can delete. `bytes` is -1 when the size can't be read.
public struct CleanTarget: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var bytes: Int64
    public init(id: String, label: String, bytes: Int64) { self.id = id; self.label = label; self.bytes = bytes }
}

/// The Mac's auto-act settings, for display on the phone.
public struct AutoActSummary: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var afterSeconds: Int
    public var quitApps: [String]
    public var closeIdleClaude: Bool
    public var cleanTargets: [String]

    public init(enabled: Bool, afterSeconds: Int, quitApps: [String], closeIdleClaude: Bool, cleanTargets: [String]) {
        self.enabled = enabled; self.afterSeconds = afterSeconds; self.quitApps = quitApps
        self.closeIdleClaude = closeIdleClaude; self.cleanTargets = cleanTargets
    }
}

public struct SystemHealth: Codable, Hashable, Sendable {
    public var at: Date
    public var level: HealthLevel
    /// Non-ok signals, worst first, e.g. "swap 9.6/10 GB".
    public var reasons: [String]
    public var pressure: HealthLevel
    public var memTotal: Int64
    public var memUsed: Int64
    public var memCompressed: Int64
    public var swapUsed: Int64
    public var swapTotal: Int64
    public var diskFree: Int64
    public var diskTotal: Int64
    public var load1: Double
    public var load5: Double
    public var cores: Int
    /// nominal | fair | serious | critical
    public var thermal: String
    public var apps: [AppUsage]
    public var cleanable: [CleanTarget]
    /// Oldest first. Streamed updates carry only the newest point.
    public var history: [HealthPoint]
    public var auto: AutoActSummary

    public init(at: Date, level: HealthLevel, reasons: [String], pressure: HealthLevel, memTotal: Int64, memUsed: Int64,
                memCompressed: Int64, swapUsed: Int64, swapTotal: Int64, diskFree: Int64, diskTotal: Int64,
                load1: Double, load5: Double, cores: Int, thermal: String, apps: [AppUsage], cleanable: [CleanTarget],
                history: [HealthPoint], auto: AutoActSummary) {
        self.at = at; self.level = level; self.reasons = reasons; self.pressure = pressure
        self.memTotal = memTotal; self.memUsed = memUsed; self.memCompressed = memCompressed
        self.swapUsed = swapUsed; self.swapTotal = swapTotal; self.diskFree = diskFree; self.diskTotal = diskTotal
        self.load1 = load1; self.load5 = load5; self.cores = cores; self.thermal = thermal
        self.apps = apps; self.cleanable = cleanable; self.history = history; self.auto = auto
    }

    /// The same reading with only the newest history point (what the stream sends every 5 s).
    public var latestOnly: SystemHealth {
        var h = self
        h.history = history.last.map { [$0] } ?? []
        return h
    }
}

// MARK: - Command bodies

public struct QuitAppBody: Codable, Sendable {
    public var requestId: String
    public var appId: String
    public init(requestId: String = UUID().uuidString, appId: String) { self.requestId = requestId; self.appId = appId }
}

public struct KillBody: Codable, Sendable {
    public var requestId: String
    public var pid: Int32
    public init(requestId: String = UUID().uuidString, pid: Int32) { self.requestId = requestId; self.pid = pid }
}

public struct CleanBody: Codable, Sendable {
    public var requestId: String
    public var targets: [String]
    public init(requestId: String = UUID().uuidString, targets: [String]) { self.requestId = requestId; self.targets = targets }
}

public struct AutoActBody: Codable, Sendable {
    public var requestId: String
    public var enabled: Bool
    public init(requestId: String = UUID().uuidString, enabled: Bool) { self.requestId = requestId; self.enabled = enabled }
}
