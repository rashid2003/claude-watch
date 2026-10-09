import SwiftUI
import WatchProtocol

/// A chat line in the menu-bar style: "▸ title · folder   ☑2 ◐1 ☐3 working", then account/time and status.
struct SessionRowView: View {
    @Environment(RemoteStore.self) private var store
    let session: SessionStatus
    var showAccount = true
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let prompt = store.snapshot?.prompts(forChat: session.id).first
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("▸").foregroundStyle(Theme.clay).fixedSize()
                Text(session.info.title.isEmpty ? "untitled chat" : session.info.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Text("· " + Fmt.folderName(session.info.cwd))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                let act = activity(prompt: prompt)
                Text(act.0).foregroundStyle(act.1).lineLimit(1).fixedSize()
                    .contentTransition(.interpolate)
                    .animation(.snappy, value: act.0)
            }
            HStack(spacing: 6) {
                if showAccount {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(AccountColor.color(for: session.info.profileId))
                        .frame(width: 6, height: 6)
                    Text(store.snapshot?.accountName(forProfile: session.info.profileId) ?? session.info.profileId)
                        .truncationMode(.middle)
                    Text("·").foregroundStyle(.tertiary)
                }
                if session.info.isTerminalChat { TerminalTag() }
                // The time always shows in full; a long account name gives way instead.
                Text(Fmt.relativeAgo(session.info.lastActivityAt)).fixedSize()
                Spacer(minLength: 4)
                if !session.tasks.isEmpty { Text(taskSummary).fixedSize() }
            }
            .font(Theme.monoTiny)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.leading, 14)
            if let d = detail(prompt: prompt) {
                Text(d.0)
                    .foregroundStyle(d.1)
                    .lineLimit(typeSize > .large ? 2 : 1)
                    .padding(.leading, 14)
            }
        }
        .font(Theme.monoSmall)
        .padding(.vertical, 7)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var taskSummary: String {
        let d = session.tasks.filter { $0.status == .completed }.count
        let p = session.tasks.filter { $0.status == .in_progress }.count
        return "☑\(d) ◐\(p) ☐\(session.tasks.count - d - p)"
    }

    private func activity(prompt: PendingPrompt?) -> (String, Color) {
        if prompt != nil { return ("needs you", Theme.clay) }
        if session.isRateLimited { return ("hit limit", Theme.red) }
        switch session.activity {
        case .working: return ("working", Theme.yellow)
        case .waiting: return ("needs you", Theme.clay)
        case .failed: return (session.tail.lastRateLimit != nil ? "hit limit" : "failed", Theme.red)
        case .idle: return ("idle", .secondary)
        }
    }

    private func detail(prompt: PendingPrompt?) -> (String, Color)? {
        if let prompt {
            if prompt.viewOnly == true { return ("◆ \(prompt.toolName): \(prompt.summary) · answer in terminal", Theme.clay) }
            return prompt.kind == .permission
                ? ("◆ \(prompt.toolName): \(prompt.summary)", Theme.clay)
                : ("◆ question · answer on mac", Theme.clay)
        }
        if session.isWorking, let line = session.work?.line {
            return ("↳ " + line, .secondary)
        }
        if let t = session.tasks.first(where: { $0.status == .in_progress }) {
            return ("◐ " + (t.activeForm ?? t.subject), .secondary)
        }
        if session.canContinue {
            let reset = session.tail.lastRateLimit?.resetsAt.map { " · resets " + Fmt.time($0) } ?? ""
            return ("✗ " + (session.tail.lastRateLimit?.text ?? "usage limit") + reset, Theme.red)
        }
        if session.activity == .failed, let e = session.info.desktopError { return ("✗ " + e, Theme.red) }
        return nil
    }
}

/// An account in the menu-bar style: state dot, name, badge, 5h / 7d limit rows, tokens and retry mode.
struct AccountRowView: View {
    @Environment(RemoteStore.self) private var store
    let account: AccountStatus
    let now: Date
    var showSessions = true
    var showDetailsLink = true
    @ScaledMetric(relativeTo: .footnote) private var pickerWidth: CGFloat = 170

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            LimitRow(label: "5h", f: account.fiveHour, pace: account.tokensPerHourNow, now: now)
            LimitRow(label: "7d", f: account.weekly, pace: account.tokensPerHourNow, now: now)
            Text("tok 5h \(Fmt.tokens(account.tokens5h)) · 7d \(Fmt.tokens(account.tokens7d))"
                 + (account.tokensPerHourNow > 0 ? " · \(Fmt.tokens(account.tokensPerHourNow))/h" : ""))
                .font(Theme.monoSmall)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 10) {
                Text("retry").font(Theme.monoSmall).foregroundStyle(.secondary).fixedSize()
                Picker("Retry mode", selection: modeBinding) {
                    ForEach(RetryMode.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: pickerWidth)
                .disabled(!store.canSend || store.isPending(Keys.mode(account.id)))
                if store.isPending(Keys.mode(account.id)) { ProgressView().controlSize(.mini) }
                Spacer()
                if showDetailsLink {
                    NavigationLink(value: AccountRoute(profileId: account.id)) {
                        Text("details ›")
                    }
                    .buttonStyle(.clayLink)
                    .fixedSize()
                }
            }
            if showSessions {
                ForEach(visibleSessions) { s in
                    NavigationLink(value: ChatRoute(id: s.id)) {
                        SessionRowView(session: s, showAccount: false)
                    }
                    .buttonStyle(.row)
                    .foregroundStyle(.primary)
                }
            }
        }
        .padding(.vertical, 10)
    }

    private var header: some View {
        // On a phone the Mac's one-line "name · id  badge" doesn't fit, so the id gets its own line.
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Circle().fill(Theme.color(account.state)).frame(width: 7, height: 7)
                Text(account.profile.name).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Badge(text: badge, color: Theme.color(account.state))
                    .animation(.snappy, value: badge)
            }
            .font(Theme.mono)
            Text(account.profile.id + (account.alsoOpenIn.isEmpty ? "" : " + " + account.alsoOpenIn.joined(separator: ", ")))
                .font(Theme.monoTiny)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, 13)
        }
        .accessibilityElement(children: .combine)
    }

    private var badge: String {
        var b = account.running || [.offline, .working].contains(account.state) ? Theme.label(account.state) : "not running"
        if account.state == .limited, let u = account.limitedUntil { b += " · " + Fmt.time(u, now: now) }
        return b
    }

    private var modeBinding: Binding<RetryMode> {
        Binding(get: { account.retryMode }, set: { m in
            guard m != account.retryMode else { return }
            Task { await store.perform(.setMode(profileId: account.id, mode: m)) }
        })
    }

    private var visibleSessions: [SessionStatus] {
        let active = account.sessions.filter { $0.activity != .idle }.prefix(4)
        let idle = account.sessions.filter { $0.activity == .idle }.prefix(max(0, 2 - active.count))
        return Array(active) + Array(idle)
    }
}

#Preview("Rows") {
    NavigationStack {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Fixtures.snapshot.accounts) { a in
                    Divider()
                    AccountRowView(account: a, now: .now)
                }
            }
            .padding(.horizontal, 16)
        }
        .screenBackground()
    }
    .environment(RemoteStore(preview: Fixtures.snapshot))
    .tint(Theme.clay)
}
