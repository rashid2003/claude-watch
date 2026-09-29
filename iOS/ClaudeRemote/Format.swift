import Foundation
import WatchProtocol

/// Port of `Fmt` from WatchCore (not available on iOS), so the phone says exactly what the Mac menu says.
enum Fmt {
    static func duration(_ s: TimeInterval) -> String {
        let s = max(0, s)
        if s < 60 { return "\(Int(s))s" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 {
            let h = Int(s / 3600), m = Int(s.truncatingRemainder(dividingBy: 3600) / 60)
            return m == 0 ? "\(h)h" : "\(h)h\(String(format: "%02d", m))m"
        }
        return String(format: "%.1fd", s / 86400)
    }

    static func tokens(_ n: Double) -> String {
        switch n {
        case ..<1000: return "\(Int(n))"
        case ..<1_000_000: return "\(Int(n / 1000))k"
        default: return String(format: "%.1fM", n / 1_000_000)
        }
    }

    static func percent(_ p: Double?) -> String {
        guard let p else { return "—" }
        return "\(Int(p.rounded()))%"
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mma"; f.amSymbol = "am"; f.pmSymbol = "pm"; return f
    }()
    private static let dayClock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE h:mma"; f.amSymbol = "am"; f.pmSymbol = "pm"; return f
    }()

    static func time(_ d: Date, now: Date = Date()) -> String {
        d.timeIntervalSince(now) < 20 * 3600 && Calendar.current.isDate(d, inSameDayAs: now)
            ? clock.string(from: d) : dayClock.string(from: d)
    }

    /// "~48m to cap", "resets 4:50am", "safe · resets …", "—"
    static func forecast(_ f: LimitForecast, pace: Double = 0, now: Date = Date()) -> String {
        if let p = f.percent, p >= 100 {
            return f.resetsAt.map { "resets " + time($0, now: now) } ?? "at cap"
        }
        if f.resetsFirst, let r = f.resetsAt { return "safe · resets " + time(r, now: now) }
        if let h = f.hitsAt { return "~" + duration(h.timeIntervalSince(now)) + " to cap" }
        if pace > 0 && (f.ratePerHour ?? 0) < 0.05 { return "learning pace…" }
        if let r = f.resetsAt, f.ratePerHour != nil { return "idle · resets " + time(r, now: now) }
        return f.percent == nil ? "no data yet" : "idle"
    }

    static func ago(_ d: Date?, now: Date = Date()) -> String {
        guard let d else { return "never" }
        return duration(now.timeIntervalSince(d)) + " ago"
    }

    /// Compact relative time for list rows: "now", "4m", "2h", "Tue", "12 Sep".
    static func relative(_ d: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(d)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        if s < 6 * 86400 { return d.formatted(.dateTime.weekday(.abbreviated)) }
        return d.formatted(.dateTime.day().month(.abbreviated))
    }

    /// "just now", "4m ago", "2h ago", "Tue", "12 Sep".
    static func relativeAgo(_ d: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(d)
        if s < 60 { return "just now" }
        return s < 86400 ? relative(d, now: now) + " ago" : relative(d, now: now)
    }

    /// Last path component of a working directory ("~" for the home folder).
    static func folderName(_ cwd: String) -> String {
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        if trimmed.isEmpty { return "—" }
        let last = (trimmed as NSString).lastPathComponent
        if trimmed.split(separator: "/").count == 2 && trimmed.hasPrefix("/Users/") { return "~" }
        return last
    }
}
