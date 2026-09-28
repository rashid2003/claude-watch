import Foundation

public enum Forecaster {
    public struct Window {
        public var length: TimeInterval
        public var slopeLookback: TimeInterval   // for sample-based slope
        public var paceLookback: TimeInterval    // for token-based pace
        public var value: KeyPath<UsageSample, Double>
        public var kind: LimitKind

        public static let fiveHour = Window(length: 5 * 3600, slopeLookback: 3600, paceLookback: 3600,
                                            value: \.fiveHour, kind: .fiveHour)
        public static let weekly = Window(length: 7 * 86400, slopeLookback: 12 * 3600, paceLookback: 6 * 3600,
                                          value: \.weekly, kind: .weekly)
    }

    /// Samples from the org the profile is currently signed into.
    public static func currentOrgSamples(_ samples: [UsageSample]) -> [UsageSample] {
        guard let org = samples.last?.org else { return [] }
        return samples.filter { $0.org == org }
    }

    /// Index of the first sample in the current usage window (after the last reset/drop).
    static func windowStartIndex(_ s: [UsageSample], _ w: Window) -> Int {
        guard s.count > 1 else { return 0 }
        var i = s.count - 1
        while i > 0 {
            let prev = s[i - 1][keyPath: w.value], cur = s[i][keyPath: w.value]
            let gap = s[i].t.timeIntervalSince(s[i - 1].t)
            if cur + 5 < prev || gap >= w.length { break }
            i -= 1
        }
        return i
    }

    /// Estimated start of the current window (nil when usage in it is still 0).
    static func windowStart(_ s: [UsageSample], _ w: Window) -> Date? {
        let i = windowStartIndex(s, w)
        guard let firstUsed = s[i...].firstIndex(where: { $0[keyPath: w.value] > 0 }) else { return nil }
        if firstUsed > i {
            // Rose from 0 between two samples: take the midpoint.
            let a = s[firstUsed - 1].t, b = s[firstUsed].t
            return a.addingTimeInterval(b.timeIntervalSince(a) / 2)
        }
        return s[firstUsed].t
    }

    /// Learned "% of limit per weighted token" from consecutive samples within one window.
    public static func percentPerToken(_ s: [UsageSample], _ w: Window, tokens: (Date, Date) -> Double,
                                       now: Date = Date()) -> Double? {
        var dp = 0.0, dt = 0.0, pairs = 0
        let horizon = now.addingTimeInterval(-7 * 86400)
        for (a, b) in zip(s, s.dropFirst()) where a.t > horizon {
            let gap = b.t.timeIntervalSince(a.t)
            let d = b[keyPath: w.value] - a[keyPath: w.value]
            guard gap > 0, gap < 2 * 3600, d > 0, b[keyPath: w.value] < 100 else { continue }
            let tk = tokens(a.t, b.t)
            guard tk > 0 else { continue }
            dp += d; dt += tk; pairs += 1
        }
        guard pairs >= 2, dt > 0 else { return nil }
        return dp / dt
    }

    public static func forecast(samples raw: [UsageSample], window w: Window, rateLimits: [RateLimitHit],
                                tokens: (Date, Date) -> Double, now: Date = Date()) -> LimitForecast {
        let s = currentOrgSamples(raw)
        var f = LimitForecast(percent: nil, samplePercent: nil, sampleAt: nil, ratePerHour: nil,
                              hitsAt: nil, resetsAt: nil, resetsFirst: false)
        let ratio = percentPerToken(s, w, tokens: tokens, now: now)
        let start = s.isEmpty ? nil : windowStart(s, w)

        // Reset time: an explicit one from a rate-limit error wins.
        let explicit = rateLimits.filter { $0.kind == w.kind }.compactMap(\.resetsAt).max()
        if let e = explicit, e > (start ?? .distantPast) { f.resetsAt = e }
        else if let start { f.resetsAt = start.addingTimeInterval(w.length) }

        guard let last = s.last else {
            // No samples at all: token pace only, and no absolute percentage.
            return f
        }
        f.sampleAt = last.t
        let lastValue = last[keyPath: w.value]
        f.samplePercent = lastValue

        var base = lastValue, baseAt = last.t
        if let r = f.resetsAt, r <= now, r > last.t {
            base = 0; baseAt = r                      // window rolled over since the sample
            f.resetsAt = nil
        }
        if let ratio {
            base += tokens(baseAt, now) * ratio
        }
        let pct = min(100, max(0, base))
        f.percent = pct

        // Pace: token-based when calibrated, otherwise the samples' own slope.
        var rates: [(Double, Double)] = []
        if let ratio {
            let lb = w.paceLookback
            rates.append((tokens(now.addingTimeInterval(-lb), now) * ratio / (lb / 3600), 0.6))
        }
        let recent = s.filter { $0.t >= now.addingTimeInterval(-w.slopeLookback) && $0.t >= (start ?? .distantPast) }
        if let a = recent.first, let b = recent.last, b.t.timeIntervalSince(a.t) >= 600 {
            let slope = (b[keyPath: w.value] - a[keyPath: w.value]) / (b.t.timeIntervalSince(a.t) / 3600)
            if slope >= 0 { rates.append((slope, 0.4)) }
        }
        if !rates.isEmpty {
            let wsum = rates.map(\.1).reduce(0, +)
            let rate = rates.map { $0.0 * $0.1 }.reduce(0, +) / wsum
            f.ratePerHour = rate
            if pct >= 100 {
                f.hitsAt = now
            } else if rate > 0.05 {
                f.hitsAt = now.addingTimeInterval((100 - pct) / rate * 3600)
            }
        } else if pct >= 100 {
            f.hitsAt = now
        }
        if let h = f.hitsAt, let r = f.resetsAt, h > r { f.resetsFirst = true }
        return f
    }
}
