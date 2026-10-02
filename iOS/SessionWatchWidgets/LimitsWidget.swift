import SwiftUI
import WatchProtocol
import WidgetKit

struct LimitsEntry: TimelineEntry {
    var date: Date
    var limits: LiveLimits?
    var macName: String
    var fetchedAt: Date?
}

/// Asks the Mac directly when it can (Tailscale or the same network), otherwise shows what the app last saw.
struct LimitsProvider: TimelineProvider {
    func placeholder(in context: Context) -> LimitsEntry {
        LimitsEntry(date: Date(), limits: .sample, macName: "Mac", fetchedAt: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (LimitsEntry) -> Void) {
        if context.isPreview { return completion(placeholder(in: context)) }
        let c = WidgetShare.load()
        completion(LimitsEntry(date: Date(), limits: c?.limits ?? .sample, macName: c?.macName ?? "Mac", fetchedAt: c?.fetchedAt))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LimitsEntry>) -> Void) {
        Task {
            var cached = WidgetShare.load()
            if let link = WidgetShare.Link.load(), let fresh = await link.fetch() {
                WidgetShare.save(fresh, macName: link.macName)
                cached = WidgetShare.Cached(limits: fresh, macName: link.macName, fetchedAt: Date())
            }
            let now = Date()
            let entry = LimitsEntry(date: now, limits: cached?.limits, macName: cached?.macName ?? "Mac", fetchedAt: cached?.fetchedAt)
            // Refresh soon after the next window resets or account comes back, and at least every 15 minutes.
            let soonest = (cached?.limits.accounts ?? []).flatMap { [$0.limitedUntilDate, $0.fiveResetsDate] }
                .compactMap { $0 }.filter { $0 > now }.min()
            let next = min(soonest.map { $0.addingTimeInterval(30) } ?? .distantFuture, now.addingTimeInterval(15 * 60))
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }
}

struct LimitsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetShare.kind, provider: LimitsProvider()) { entry in
            LimitsWidgetView(entry: entry)
                .containerBackground(for: .widget) { WTheme.graphite }
        }
        .configurationDisplayName("Claude limits")
        .description("5-hour and weekly use for every account on your Mac.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct LimitsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LimitsEntry

    var body: some View {
        if let l = entry.limits {
            switch family {
            case .accessoryInline: inline(l)
            case .accessoryCircular: circular(l)
            case .accessoryRectangular: rectangular(l)
            case .systemSmall: small(l)
            default: list(l)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("✻ session-watch").foregroundStyle(WTheme.clay)
                Text("Open Session Watch and pair with your Mac.").foregroundStyle(WTheme.dim)
            }
            .font(WTheme.mono(11))
            .foregroundStyle(.white)
        }
    }

    // MARK: Lock Screen

    private func inline(_ l: LiveLimits) -> some View {
        let h = l.headline
        return Text("✻ \(WTheme.percent(h?.five)) 5h · \(WTheme.percent(h?.week)) 7d" + (l.prompts > 0 ? " · ◆\(l.prompts)" : ""))
    }

    private func circular(_ l: LiveLimits) -> some View {
        let h = l.headline
        return Gauge(value: Double(min(100, h?.five ?? 0)), in: 0...100) {
            Text("5h")
        } currentValueLabel: {
            Text(h?.state == .limited ? "lim" : "\(h?.five ?? 0)").font(WTheme.mono(12, .semibold))
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .widgetAccentable()
    }

    private func rectangular(_ l: LiveLimits) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(l.accounts.prefix(3)) { a in
                HStack(spacing: 4) {
                    Text(a.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 2)
                    Text(a.state == .limited ? "lim" : WTheme.percent(a.five)).fontWeight(.semibold)
                    Text(WTheme.percent(a.week)).foregroundStyle(.secondary)
                }
            }
        }
        .font(WTheme.mono(11))
        .widgetAccentable()
    }

    // MARK: Home Screen / Mac desktop

    private func small(_ l: LiveLimits) -> some View {
        let h = l.headline
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("✻").foregroundStyle(WTheme.clay)
                Text(h?.name ?? "limits").fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if l.prompts > 0 { Text("◆\(l.prompts)").foregroundStyle(WTheme.clay).fixedSize() }
            }
            .font(WTheme.mono(11))
            if let h, h.state == .limited {
                Text("limited").font(WTheme.mono(20, .bold)).foregroundStyle(WTheme.red)
                Countdown(date: h.limitedUntilDate, prefix: "back in ").font(WTheme.mono(11)).foregroundStyle(WTheme.dim)
            } else {
                Text(WTheme.percent(h?.five)).font(WTheme.mono(30, .bold)).foregroundStyle(WTheme.level(h?.five))
                    .contentTransition(.numericText())
                Meter(percent: h?.five)
                Countdown(date: h?.fiveResetsDate, prefix: "5h ↺ ").font(WTheme.mono(10)).foregroundStyle(WTheme.dim)
            }
            Spacer(minLength: 0)
            HStack {
                Text("7d \(WTheme.percent(h?.week))").foregroundStyle(WTheme.level(h?.week))
                Spacer(minLength: 0)
                if l.accounts.count > 1 { Text("+\(l.accounts.count - 1 + l.hidden)").foregroundStyle(WTheme.dim) }
            }
            .font(WTheme.mono(10))
        }
        .foregroundStyle(.white)
    }

    private func list(_ l: LiveLimits) -> some View {
        let rows = family == .systemLarge ? l.accounts : Array(l.accounts.prefix(3))
        return VStack(alignment: .leading, spacing: family == .systemLarge ? 10 : 6) {
            HStack(spacing: 6) {
                Text("✻").foregroundStyle(WTheme.clay)
                Text("session-watch").fontWeight(.semibold)
                Spacer(minLength: 4)
                StatusTags(limits: l)
            }
            .font(WTheme.mono(11))
            ForEach(rows) { AccountLine(account: $0, compact: family != .systemLarge) }
            Spacer(minLength: 0)
            HStack {
                Text(entry.macName).lineLimit(1)
                Spacer()
                if let at = entry.fetchedAt { Text(at, style: .relative).monospacedDigit() + Text(" ago") }
            }
            .font(WTheme.mono(9))
            .foregroundStyle(WTheme.dim)
        }
        .foregroundStyle(.white)
    }
}

extension LiveLimits {
    static var sample: LiveLimits {
        let now = Date().timeIntervalSince1970
        return LiveLimits(accounts: [
            .init(id: "default", name: "lajward.dev", state: .working, five: 62, week: 31, fiveResets: now + 6000, working: 2),
            .init(id: "account-1", name: "gmail.com", state: .limited, five: 100, week: 74, limitedUntil: now + 2600),
            .init(id: "account-2", name: "universal.systems", state: .free, five: 8, week: 12),
        ], prompts: 1, working: 2, updated: now)
    }
}

#Preview("Medium", as: .systemMedium) {
    LimitsWidget()
} timeline: {
    LimitsEntry(date: .now, limits: .sample, macName: "MacBook Pro", fetchedAt: .now)
}
