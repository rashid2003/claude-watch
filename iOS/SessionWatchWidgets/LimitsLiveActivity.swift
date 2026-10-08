import ActivityKit
import SwiftUI
import WatchProtocol
import WidgetKit

/// Lock Screen banner, Dynamic Island, and (macOS 26+, phone nearby) the Mac's menu bar.
///
/// Stale (no push from the Mac before its stale date) or marked disconnected by the app, it dims the numbers and
/// says when the Mac was last seen.
struct LimitsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LimitsActivityAttributes.self) { context in
            LockScreenLimits(limits: context.state, macName: context.attributes.macName,
                             offline: context.isStale || context.state.disconnected)
                .activityBackgroundTint(WTheme.graphite.opacity(0.92))
                .activitySystemActionForegroundColor(WTheme.clay)
        } dynamicIsland: { context in
            let l = context.state
            let head = l.headline
            let offline = context.isStale || l.disconnected
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
                    StatusTags(limits: l, offline: offline).font(WTheme.mono(12, .semibold)).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        ForEach(l.accounts.prefix(3)) { AccountLine(account: $0, compact: true).dimmed(offline) }
                        if offline { OfflineNote(lastSeen: l.updatedDate, reason: l.offline) }
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
                }
            } compactLeading: {
                HStack(spacing: 3) {
                    Text("✻").foregroundStyle(offline ? WTheme.dim : WTheme.clay)
                    if offline {
                        Text(WTheme.percent(head?.five)).foregroundStyle(WTheme.dim)
                    } else if let head, head.state == .limited {
                        Text("lim").foregroundStyle(WTheme.red)
                    } else {
                        Text(WTheme.percent(head?.five)).foregroundStyle(WTheme.level(head?.five))
                    }
                }
                .font(WTheme.mono(13, .semibold))
            } compactTrailing: {
                Group {
                    if offline {
                        Text("offline").foregroundStyle(WTheme.dim)
                    } else if let head, head.state == .limited, let until = head.limitedUntilDate, until > Date() {
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
                .tint(offline ? Color.gray : head?.state == .limited ? WTheme.red : WTheme.level(head?.pressure))
                .opacity(offline ? 0.5 : 1)
            }
            .keylineTint(WTheme.clay)
        }
    }
}

/// The Lock Screen card: a header line, then one line per account.
struct LockScreenLimits: View {
    let limits: LiveLimits
    let macName: String
    var offline = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("✻").foregroundStyle(WTheme.clay)
                Text("session-watch").fontWeight(.semibold)
                Text(macName).foregroundStyle(WTheme.dim).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                StatusTags(limits: limits, offline: offline)
            }
            .font(WTheme.mono(12))
            ForEach(limits.accounts) { AccountLine(account: $0, compact: limits.accounts.count > 2).dimmed(offline) }
            if limits.hidden > 0 {
                Text("+\(limits.hidden) more").font(WTheme.mono(10)).foregroundStyle(WTheme.dim)
            }
            if offline { OfflineNote(lastSeen: limits.updatedDate, reason: limits.offline) }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// "◆2  3 working" — what needs you, at a glance. Just "offline" when the numbers can't be trusted.
struct StatusTags: View {
    let limits: LiveLimits
    var offline = false
    var body: some View {
        HStack(spacing: 6) {
            if offline {
                Text("○ offline").foregroundStyle(WTheme.dim)
            } else if limits.prompts > 0 || limits.working > 0 {
                tags
            } else {
                Text("idle").foregroundStyle(WTheme.dim)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    @ViewBuilder private var tags: some View {
        if limits.prompts > 0 { Text("◆\(limits.prompts)").foregroundStyle(WTheme.clay) }
        if limits.working > 0 { Text("\(limits.working) working").foregroundStyle(WTheme.yellow) }
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

/// "Mac offline · last seen 6:12", from when the Mac took its last snapshot (with the weekday if not today).
/// "Mac asleep" or "Mac app quit" when the Mac said so in its last push.
struct OfflineNote: View {
    let lastSeen: Date
    var reason: String?
    var body: some View {
        let today = Calendar.current.isDateInToday(lastSeen)
        HStack(spacing: 0) {
            Text(title).foregroundStyle(WTheme.red)
            Text(" · last seen ")
            Text(lastSeen, format: today ? .dateTime.hour().minute() : .dateTime.weekday().hour().minute())
        }
        .font(WTheme.mono(10))
        .foregroundStyle(WTheme.dim)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch reason {
        case LiveLimits.Offline.sleep: "Mac asleep"
        case LiveLimits.Offline.quit: "Mac app quit"
        default: "Mac offline"
        }
    }
}

extension View {
    /// Greys out numbers that may be out of date.
    func dimmed(_ on: Bool) -> some View { saturation(on ? 0 : 1).opacity(on ? 0.45 : 1) }
}

#if DEBUG
#Preview("Lock Screen", as: .content, using: LimitsActivityAttributes(macName: "MacBook Pro")) {
    LimitsLiveActivity()
} contentStates: {
    LiveLimits.sample
    LiveLimits.sampleOffline
    LiveLimits.sampleAsleep
}

private extension LiveLimits {
    static var sampleOffline: LiveLimits { var l = sample; l.connected = false; return l }
    static var sampleAsleep: LiveLimits { sample.goingOffline(LiveLimits.Offline.sleep) }
}
#endif
