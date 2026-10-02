import ActivityKit
import SwiftUI
import WatchProtocol
import WidgetKit

/// Lock Screen banner, Dynamic Island, and (macOS 26+, phone nearby) the Mac's menu bar.
struct LimitsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LimitsActivityAttributes.self) { context in
            LockScreenLimits(limits: context.state, macName: context.attributes.macName, stale: context.isStale)
                .activityBackgroundTint(WTheme.graphite.opacity(0.92))
                .activitySystemActionForegroundColor(WTheme.clay)
        } dynamicIsland: { context in
            let l = context.state
            let head = l.headline
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 5) {
                        Text("✻").foregroundStyle(WTheme.clay)
                        Text("limits").fontWeight(.semibold)
                    }
                    .font(WTheme.mono(13))
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    StatusTags(limits: l).font(WTheme.mono(12, .semibold)).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        ForEach(l.accounts.prefix(3)) { AccountLine(account: $0, compact: true) }
                        if context.isStale { StaleNote() }
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
                }
            } compactLeading: {
                HStack(spacing: 3) {
                    Text("✻").foregroundStyle(WTheme.clay)
                    if let head, head.state == .limited {
                        Text("lim").foregroundStyle(WTheme.red)
                    } else {
                        Text(WTheme.percent(head?.five)).foregroundStyle(WTheme.level(head?.five))
                    }
                }
                .font(WTheme.mono(13, .semibold))
            } compactTrailing: {
                Group {
                    if let head, head.state == .limited, let until = head.limitedUntilDate, until > Date() {
                        Text(timerInterval: Date()...until, countsDown: true, showsHours: true)
                            .monospacedDigit()
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 52)
                            .foregroundStyle(WTheme.red)
                    } else if l.prompts > 0 {
                        Text("◆\(l.prompts)").foregroundStyle(WTheme.clay)
                    } else {
                        Text("7d " + WTheme.percent(head?.week)).foregroundStyle(WTheme.dim)
                    }
                }
                .font(WTheme.mono(12, .semibold))
            } minimal: {
                Gauge(value: Double(min(100, head?.pressure ?? 0)), in: 0...100) {
                    Text("✻")
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(head?.state == .limited ? WTheme.red : WTheme.level(head?.pressure))
            }
            .keylineTint(WTheme.clay)
        }
    }
}

/// The Lock Screen card: a header line, then one line per account.
struct LockScreenLimits: View {
    let limits: LiveLimits
    let macName: String
    var stale = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("✻").foregroundStyle(WTheme.clay)
                Text("session-watch").fontWeight(.semibold)
                Text(macName).foregroundStyle(WTheme.dim).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                StatusTags(limits: limits)
            }
            .font(WTheme.mono(12))
            ForEach(limits.accounts) { AccountLine(account: $0, compact: limits.accounts.count > 2) }
            if limits.hidden > 0 {
                Text("+\(limits.hidden) more").font(WTheme.mono(10)).foregroundStyle(WTheme.dim)
            }
            if stale { StaleNote() }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// "◆2  3 working" — what needs you, at a glance.
struct StatusTags: View {
    let limits: LiveLimits
    var body: some View {
        HStack(spacing: 6) {
            if limits.prompts > 0 { Text("◆\(limits.prompts)").foregroundStyle(WTheme.clay) }
            if limits.working > 0 { Text("\(limits.working) working").foregroundStyle(WTheme.yellow) }
            if limits.prompts == 0 && limits.working == 0 { Text("idle").foregroundStyle(WTheme.dim) }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// One account: state dot, name, the 5-hour meter and the weekly figure, or how long until it's back.
struct AccountLine: View {
    let account: LiveLimits.Account
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(WTheme.color(account.state)).frame(width: 6, height: 6)
                Text(account.name).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                if !compact, let org = account.org {
                    Text(org).foregroundStyle(WTheme.dim).lineLimit(1)
                }
                Spacer(minLength: 4)
                trailing
            }
            .font(WTheme.mono(compact ? 11 : 12))
            if account.state != .limited {
                HStack(spacing: 6) {
                    Text("5h").foregroundStyle(WTheme.dim)
                    Meter(percent: account.five, height: compact ? 4 : 5)
                    Text(WTheme.percent(account.five)).frame(minWidth: 34, alignment: .trailing)
                    Text("7d").foregroundStyle(WTheme.dim)
                    Text(WTheme.percent(account.week)).foregroundStyle(WTheme.level(account.week))
                        .frame(minWidth: 34, alignment: .trailing)
                }
                .font(WTheme.mono(10))
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var trailing: some View {
        if account.state == .limited {
            HStack(spacing: 4) {
                Text("limited").foregroundStyle(WTheme.red)
                if let until = account.limitedUntilDate, until > Date() {
                    Text(timerInterval: Date()...until, countsDown: true, showsHours: true)
                        .monospacedDigit().multilineTextAlignment(.trailing).frame(maxWidth: 62)
                }
            }
        } else if let reset = account.fiveResetsDate, reset > Date() {
            HStack(spacing: 2) {
                Text("↺").foregroundStyle(WTheme.dim)
                Text(timerInterval: Date()...reset, countsDown: true, showsHours: true)
                    .monospacedDigit().multilineTextAlignment(.trailing).frame(maxWidth: 62)
            }
            .foregroundStyle(WTheme.dim)
        } else if account.working > 0 {
            Text("\(account.working) working").foregroundStyle(WTheme.yellow)
        } else {
            Text(WTheme.label(account.state)).foregroundStyle(WTheme.color(account.state))
        }
    }
}

struct StaleNote: View {
    var body: some View {
        Text("… waiting for the Mac").font(WTheme.mono(10)).foregroundStyle(WTheme.dim)
    }
}

#if DEBUG
#Preview("Lock Screen", as: .content, using: LimitsActivityAttributes(macName: "MacBook Pro")) {
    LimitsLiveActivity()
} contentStates: {
    LiveLimits.sample
}
#endif
