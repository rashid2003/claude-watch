import AppKit
import SwiftUI
import UserNotifications
import WatchCore

// MARK: - Model

final class WatchModel: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var snapshot: Snapshot?
    @Published var trusted = UIRetry.isTrusted
    let monitor = Monitor(ownEngine: true)

    override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        monitor.onSnapshot = { [weak self] s in
            DispatchQueue.main.async {
                self?.snapshot = s
                self?.trusted = UIRetry.isTrusted
            }
        }
        monitor.onEvent = { [weak self] e in self?.notify(e) }
        monitor.start()
        // Ask for Accessibility + Automation now, while someone is at the keyboard.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            let pid = ClaudeProcesses.list().first?.pid
            UIRetry.preflight(pid: pid)
        }
    }

    /// Menu-bar text: 5-hour usage per account, e.g. "✻ 5·72·100".
    var label: String {
        guard let s = snapshot, !s.accounts.isEmpty else { return "✻" }
        let parts = s.accounts.map { a -> String in
            if a.state == .limited { return "⏸" }
            return a.fiveHour.percent.map { String(Int($0.rounded())) } ?? "–"
        }
        return "✻ " + parts.joined(separator: "·")
    }

    func notify(_ e: WatchEvent) {
        let c = UNMutableNotificationContent()
        switch e {
        case .accountFree(let p):
            c.title = "\(p.name) is free"; c.body = "Nothing running. Ready for the next task."
        case .limitReset(let p):
            c.title = "\(p.name) limit reset"; c.body = "The account can be used again."
        case .limited(let p, let k, let u):
            let kind = k == .weekly ? "weekly" : k == .fiveHour ? "5-hour" : "usage"
            c.title = "\(p.name) hit its \(kind) limit"
            c.body = u.map { "Resets " + Fmt.time($0) + ". Failed chats will be retried then." } ?? ""
        case .capSoon(let p, let k, let at):
            c.title = "\(p.name) nearing its \(k == .weekly ? "weekly" : "5-hour") limit"
            c.body = "At this pace it hits the cap in ~\(Fmt.duration(at.timeIntervalSinceNow))."
        case .retry(let item, let msg):
            c.title = "claude-watch"; c.body = msg
            c.userInfo = ["session": item.sessionId, "profile": item.profileId]
        case .moved(let m):
            switch m.status {
            case .done: c.title = "Moved “\(m.title)”"; c.body = "Now in \(m.to.label)."
            default: c.title = "Couldn't move “\(m.title)”"; c.body = m.note ?? m.status.rawValue
            }
        }
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let info = r.notification.request.content.userInfo
        if let sid = info["session"] as? String, let pid = info["profile"] as? String {
            open(sessionId: sid, profileId: pid)
        }
        done()
    }

    func open(sessionId: String, profileId: String) {
        monitor.perform { m in
            if let p = m.profile(id: profileId) { DesktopLink.reveal(sessionId: sessionId, profile: p) }
        }
    }

    func setMode(_ mode: RetryMode, _ profileId: String) { monitor.setRetryMode(mode, for: profileId) }

    func retryNow(_ profileId: String?) {
        monitor.perform { m in m.engine.retryNow(profileId: profileId); m.refreshNow() }
    }

    func dismiss(_ id: String) { monitor.perform { m in m.engine.dismiss(itemId: id); m.refreshNow() } }
}

// MARK: - Style

enum Theme {
    static let clay = Color(red: 0.851, green: 0.467, blue: 0.341)
    static let mono = Font.system(size: 11.5, design: .monospaced)
    static let monoSmall = Font.system(size: 10.5, design: .monospaced)
    static let green = Color(red: 0.47, green: 0.75, blue: 0.47)
    static let yellow = Color(red: 0.86, green: 0.70, blue: 0.35)
    static let red = Color(red: 0.90, green: 0.40, blue: 0.40)

    static func color(_ s: AccountState) -> Color {
        switch s { case .free: green; case .working: clay; case .limited: red; case .offline: .secondary }
    }
    static func label(_ s: AccountState) -> String {
        switch s { case .free: "free"; case .working: "working"; case .limited: "limited"; case .offline: "not running" }
    }
}

// MARK: - Views

struct UsageBar: View {
    let percent: Double?
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.08))
                if let p = percent {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(p >= 90 ? Theme.red : p >= 70 ? Theme.yellow : Theme.clay)
                        .frame(width: g.size.width * min(1, max(0, p / 100)))
                }
            }
        }
        .frame(height: 5)
    }
}

struct LimitRow: View {
    let label: String
    let f: LimitForecast
    let pace: Double
    let now: Date
    var body: some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 18, alignment: .leading)
            UsageBar(percent: f.percent)
            Text(Fmt.percent(f.percent)).frame(width: 36, alignment: .trailing)
            Text(Fmt.forecast(f, pace: pace, now: now))
                .foregroundStyle(soon ? Theme.clay : .secondary)
                .frame(width: 150, alignment: .leading).lineLimit(1)
        }
        .font(Theme.mono)
    }
    var soon: Bool {
        guard let h = f.hitsAt, !f.resetsFirst, (f.percent ?? 0) < 100 else { return false }
        return h.timeIntervalSince(now) < 3600
    }
}

struct SessionRow: View {
    let s: SessionStatus
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("▸").foregroundStyle(Theme.clay)
                Text(s.info.title).lineLimit(1).truncationMode(.tail)
                Text("· " + (s.info.cwd as NSString).lastPathComponent)
                    .foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                if !s.tasks.isEmpty { Text(taskSummary).foregroundStyle(.secondary) }
                Text(activity.0).foregroundStyle(activity.1)
            }
            if let t = s.tasks.first(where: { $0.status == .in_progress }) {
                Text("◐ " + (t.activeForm ?? t.subject)).foregroundStyle(.secondary).lineLimit(1).padding(.leading, 14)
            }
        }
        .font(Theme.monoSmall)
        .padding(.vertical, 2).padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 4).fill(hover ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: open)
        .help(s.tail.lastRateLimit?.text ?? "Open in Claude")
    }

    var taskSummary: String {
        let d = s.tasks.filter { $0.status == .completed }.count
        let p = s.tasks.filter { $0.status == .in_progress }.count
        return "☑\(d) ◐\(p) ☐\(s.tasks.count - d - p)"
    }

    var activity: (String, Color) {
        switch s.activity {
        case .working: ("working", Theme.yellow)
        case .waiting: ("needs you", Theme.clay)
        case .failed: ("hit limit", Theme.red)
        case .idle: ("idle", .secondary)
        }
    }
}

struct AccountCard: View {
    let a: AccountStatus
    let now: Date
    @EnvironmentObject var model: WatchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(Theme.color(a.state)).frame(width: 7, height: 7)
                Text(a.profile.name).fontWeight(.semibold)
                Text("· " + a.profile.id + (a.alsoOpenIn.isEmpty ? "" : " + " + a.alsoOpenIn.joined(separator: ", ")))
                    .foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text(badge)
                    .font(Theme.monoSmall)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.color(a.state).opacity(0.15)))
                    .foregroundStyle(Theme.color(a.state))
            }
            .font(Theme.mono)
            LimitRow(label: "5h", f: a.fiveHour, pace: a.tokensPerHourNow, now: now)
            LimitRow(label: "7d", f: a.weekly, pace: a.tokensPerHourNow, now: now)
            HStack {
                Text("tok 5h \(Fmt.tokens(a.tokens5h)) · 7d \(Fmt.tokens(a.tokens7d))"
                     + (a.tokensPerHourNow > 0 ? " · \(Fmt.tokens(a.tokensPerHourNow))/h" : ""))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: Binding(get: { a.retryMode }, set: { model.setMode($0, a.profile.id) })) {
                    ForEach(RetryMode.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 120).controlSize(.mini)
                .help("How failed chats are retried after the limit resets")
            }
            .font(Theme.monoSmall)
            ForEach(visibleSessions) { s in
                SessionRow(s: s) { model.open(sessionId: s.id, profileId: s.info.profileId) }
            }
        }
        .padding(.vertical, 8)
    }

    var badge: String {
        var b = Theme.label(a.state)
        if a.state == .limited, let u = a.limitedUntil { b += " · " + Fmt.time(u, now: now) }
        return b
    }

    var visibleSessions: [SessionStatus] {
        let active = a.sessions.filter { $0.activity != .idle }.prefix(4)
        let idle = a.sessions.filter { $0.activity == .idle }.prefix(max(0, 2 - active.count))
        return Array(active) + Array(idle)
    }
}

struct QueueSection: View {
    let queue: [RetryItem]
    let accounts: [AccountStatus]
    let now: Date
    @EnvironmentObject var model: WatchModel

    var body: some View {
        let active = queue.filter { [.waiting, .running, .verifying].contains($0.status) }
        let recent = Array(queue.filter { ![.waiting, .running, .verifying].contains($0.status) }.suffix(3))
        if !active.isEmpty || !recent.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Retry queue").fontWeight(.semibold)
                    Spacer()
                    if !active.isEmpty {
                        Button("Retry now") { model.retryNow(nil) }.buttonStyle(.link).font(Theme.monoSmall)
                    }
                }
                ForEach(active) { it in row(it, mark: "⟳", color: Theme.clay, detail: when(it)) }
                ForEach(recent) { it in
                    row(it, mark: it.status == .done ? "✓" : it.status == .failed ? "✗" : "–",
                        color: it.status == .done ? Theme.green : it.status == .failed ? Theme.red : .secondary,
                        detail: it.note ?? "")
                }
            }
            .font(Theme.monoSmall)
            .padding(.vertical, 6)
        }
    }

    func row(_ it: RetryItem, mark: String, color: Color, detail: String) -> some View {
        HStack(spacing: 6) {
            Text(mark).foregroundStyle(color)
            Text(accounts.first { $0.memberProfileIds.contains(it.profileId) }?.profile.name ?? it.profileId)
                .foregroundStyle(.secondary).frame(width: 90, alignment: .leading).lineLimit(1)
            Text(it.title).lineLimit(1)
            Spacer(minLength: 4)
            Text(detail).foregroundStyle(.secondary).lineLimit(1)
            Button { model.dismiss(it.id) } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.tertiary).help("Remove from queue")
        }
        .contentShape(Rectangle())
        .onTapGesture { model.open(sessionId: it.sessionId, profileId: it.profileId) }
    }

    func when(_ it: RetryItem) -> String {
        switch it.status {
        case .verifying: return "checking reply…"
        case .waiting:
            guard let r = it.resetsAt, r > .distantPast else { return "due" }
            return r > now ? "in " + Fmt.duration(r.timeIntervalSince(now)) : "due"
        default: return it.status.rawValue
        }
    }
}

struct PopoverView: View {
    @EnvironmentObject var model: WatchModel
    @State private var showStats = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("✻").foregroundStyle(Theme.clay)
                    Text("claude-watch").fontWeight(.semibold)
                    Spacer()
                    if let s = model.snapshot {
                        Text("updated " + Fmt.ago(s.at, now: ctx.date)).foregroundStyle(.secondary)
                    }
                    Button { model.monitor.refreshNow() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Refresh")
                }
                .font(Theme.mono)
                .padding(.bottom, 4)

                if let s = model.snapshot {
                    ForEach(s.accounts) { a in
                        Divider()
                        AccountCard(a: a, now: ctx.date)
                    }
                    Divider()
                    QueueSection(queue: s.queue, accounts: s.accounts, now: ctx.date)
                    if !s.engineOwner {
                        Text("Another claude-watch process is running retries.")
                            .font(Theme.monoSmall).foregroundStyle(.secondary).padding(.vertical, 4)
                    }
                    if s.accounts.contains(where: { $0.retryMode == .ui }) && !model.trusted {
                        HStack {
                            Text("UI retries need Accessibility access.").foregroundStyle(Theme.yellow)
                            Spacer()
                            Button("Grant") { UIRetry.requestTrust() }.buttonStyle(.link)
                        }
                        .font(Theme.monoSmall).padding(.vertical, 4)
                    }
                } else {
                    Text("Reading transcripts… the first run scans the last 7 days.")
                        .font(Theme.mono).foregroundStyle(.secondary).padding(.vertical, 12)
                }

                if showStats { StatsView().padding(.vertical, 4) }

                Divider().padding(.top, 2)
                HStack(spacing: 14) {
                    Button(showStats ? "Hide stats" : "UI vs CLI stats") { showStats.toggle() }
                    Button("Config") { NSWorkspace.shared.open(Paths.config) }
                    Button("Logs") { NSWorkspace.shared.open(Paths.support) }
                    Spacer()
                    Button("Quit") { model.monitor.stop(); NSApp.terminate(nil) }
                }
                .buttonStyle(.link).font(Theme.monoSmall).padding(.top, 6)
            }
            .padding(12)
            .frame(width: 440)
        }
    }
}

struct StatsView: View {
    var body: some View {
        let stats = RetryEngine.stats()
        VStack(alignment: .leading, spacing: 2) {
            if stats.isEmpty { Text("No retries logged yet.").foregroundStyle(.secondary) }
            ForEach(stats, id: \.mode) { s in
                let rate = s.sent > 0 ? Int(Double(s.verified) / Double(s.sent) * 100) : 0
                Text("\(s.mode.rawValue.uppercased())  sent \(s.sent) · resumed \(s.verified) (\(rate)%) · no reply \(s.noResponse) · errors \(s.sendFailed)"
                     + (s.avgLatency.map { " · \(Int($0))s" } ?? ""))
            }
        }
        .font(Theme.monoSmall)
    }
}

// MARK: - App

@main
struct ClaudeWatchApp: App {
    @StateObject private var model = WatchModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environmentObject(model)
        } label: {
            Text(model.label).monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}
