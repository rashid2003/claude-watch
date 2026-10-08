import Foundation

/// The raw signals `HealthRules` rates.
public struct HealthInputs: Sendable {
    public var pressure: HealthLevel
    public var swapUsed: Int64
    public var swapTotal: Int64
    public var diskFree: Int64
    public var load5: Double
    public var cores: Int
    public var thermal: ProcessInfo.ThermalState

    public init(pressure: HealthLevel, swapUsed: Int64, swapTotal: Int64, diskFree: Int64, load5: Double, cores: Int,
                thermal: ProcessInfo.ThermalState) {
        self.pressure = pressure; self.swapUsed = swapUsed; self.swapTotal = swapTotal; self.diskFree = diskFree
        self.load5 = load5; self.cores = cores; self.thermal = thermal
    }
}

/// Rates the Mac ok / warn / critical (see docs/specs/2026-10-08-system-health-design.md §2).
public enum HealthRules {
    static let GB = 1_000_000_000.0

    public static func evaluate(_ i: HealthInputs, _ cfg: SystemConfig) -> (level: HealthLevel, reasons: [String]) {
        var signals: [(HealthLevel, String)] = []

        if i.swapTotal >= 1_000_000_000 {
            let r = Double(i.swapUsed) / Double(i.swapTotal)
            let l: HealthLevel = r > 0.90 ? .critical : r > 0.75 ? .warn : .ok
            signals.append((l, String(format: "swap %.1f/%.0f GB", Double(i.swapUsed) / GB, Double(i.swapTotal) / GB)))
        }
        let free = Double(i.diskFree) / GB
        signals.append((free < cfg.diskCriticalGB ? .critical : free < cfg.diskWarnGB ? .warn : .ok,
                        String(format: "disk %.0f GB free", free)))
        let perCore = i.load5 / Double(max(1, i.cores))
        signals.append((perCore > 4 ? .critical : perCore > 2 ? .warn : .ok,
                        String(format: "load %.0f on %d cores", i.load5, i.cores)))
        signals.append((i.pressure, "memory pressure \(i.pressure.rawValue)"))
        let thermal: HealthLevel = i.thermal == .critical ? .critical : i.thermal == .serious ? .warn : .ok
        signals.append((thermal, "thermal \(thermalName(i.thermal))"))

        let bad = signals.enumerated().filter { $0.element.0 > .ok }
            .sorted { ($0.element.0, -$0.offset) > ($1.element.0, -$1.offset) }
        return (bad.first?.element.0 ?? .ok, bad.map(\.element.1))
    }

    public static func thermalName(_ t: ProcessInfo.ThermalState) -> String {
        switch t {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

/// Decides when to alert and when to auto-act, one reading at a time.
/// A level counts once it has held for `hold`; an alert goes out when that confirmed level rises above the
/// last one alerted; the last-alerted level drops back after the Mac has stayed below it for `rearm`.
public struct HealthAlerter: Sendable {
    public static let hold: TimeInterval = 60
    public static let rearm: TimeInterval = 1800

    public private(set) var confirmed: HealthLevel = .ok
    private var candidate: HealthLevel = .ok
    private var candidateSince = Date.distantPast
    private var confirmedSince = Date.distantPast
    private var lastAlerted: HealthLevel = .ok
    private var belowSince: Date?
    private var autoFired = false

    public init() {}

    public mutating func feed(_ level: HealthLevel, at now: Date, autoEnabled: Bool,
                              autoAfter: TimeInterval) -> (alert: HealthLevel?, autoAct: Bool) {
        if level != candidate { candidate = level; candidateSince = now }
        if candidate != confirmed, now.timeIntervalSince(candidateSince) >= Self.hold {
            confirmed = candidate
            confirmedSince = now
            if confirmed != .critical { autoFired = false }
        }

        if confirmed < lastAlerted {
            let since = belowSince ?? now
            belowSince = since
            if now.timeIntervalSince(since) >= Self.rearm { lastAlerted = confirmed; belowSince = nil }
        } else {
            belowSince = nil
        }

        var alert: HealthLevel?
        if confirmed > lastAlerted { alert = confirmed; lastAlerted = confirmed }

        var act = false
        if autoEnabled, confirmed == .critical, !autoFired, now.timeIntervalSince(confirmedSince) >= autoAfter {
            act = true
            autoFired = true
        }
        return (alert, act)
    }
}

/// Notification text shared by the Mac's own notification and the iPhone push.
public enum SystemText {
    public static func gb(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1e9) }

    public static func title(_ level: HealthLevel, reasons: [String]) -> String {
        guard let r = reasons.first else { return "Mac under pressure" }
        return "Mac \(level == .critical ? "critical" : "warning"): \(r)"
    }

    public static func body(reasons: [String], apps: [AppUsage]) -> String {
        let top = apps.sorted { $0.rss > $1.rss }.prefix(2).map { "\($0.name) \(gb($0.rss))" }
        return reasons.joined(separator: " · ") + (top.isEmpty ? "" : " — " + top.joined(separator: ", "))
    }
}
