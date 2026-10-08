import AppKit
import SwiftUI
import UserNotifications
import WatchCore

// MARK: - Model

/// Sections of the main window's sidebar.
enum MainSection: String, CaseIterable, Identifiable, Hashable {
    case overview, chats, system, iphone, settings
    var id: String { rawValue }
    var title: String { self == .iphone ? "iphone" : rawValue }
    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .chats: "bubble.left.and.bubble.right"
        case .system: "memorychip"
        case .iphone: "iphone"
        case .settings: "gearshape"
        }
    }
}

final class WatchModel: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    /// One per process: the app delegate and the SwiftUI scenes share it.
    static let shared = WatchModel()

    @Published var snapshot: Snapshot?
    @Published var trusted = UIRetry.isTrusted
    @Published var chatsProfile: String?     // account picked when opening the All chats window
    @Published var bridgeTick = 0             // bumps when paired devices / pairing change
    @Published var section: MainSection? = .overview
    /// Mirror of config.json; edit it with `updateConfig` so the file and the Monitor follow.
    @Published private(set) var config = Config() {
        didSet { if config.showInDock != oldValue.showInDock { applyActivationPolicy() } }
    }
    @Published var configError: String?
    /// The Mac's resources (memory, swap, CPU, disk) and their 30-minute trend.
    @Published var health: SystemHealth?
    let monitor = Monitor(ownEngine: true)
    let system: SystemWatch
    private(set) var bridge: BridgeController?
    /// Bridge settings this process started with (changing them needs a restart).
    let bridgeAtLaunch: (enabled: Bool, port: Int)
    private var pendingWrites = 0
    /// Captured from any SwiftUI view, so AppKit callbacks (Dock click, reopen) can open the main window.
    var openWindowAction: OpenWindowAction?

    override init() {
        bridgeAtLaunch = (monitor.config.bridgeEnabled, monitor.config.bridgePort)
        system = SystemWatch(config: { [monitor] in monitor.config.system },
                             profiles: { [monitor] in ProfileDiscovery.discover(config: monitor.config) })
        super.init()
        config = monitor.config
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        var bridgeOn = monitor.config.bridgeEnabled
        #if DEBUG
        // A dev copy next to the installed app must not take over its bridge socket.
        if ProcessInfo.processInfo.environment["SW_NO_BRIDGE"] != nil { bridgeOn = false }
        #endif
        if bridgeOn {
            let b = BridgeController(monitor: monitor)
            b.onChange = { [weak self] in self?.bridgeTick += 1 }
            b.start()
            bridge = b
        }
        monitor.onSnapshot = { [weak self] s in
            guard let self else { return }
            self.bridge?.update(s)
            let cfg = self.monitor.config   // on the monitor queue: follows edits made outside the app
            DispatchQueue.main.async {
                self.snapshot = s
                self.trusted = UIRetry.isTrusted
                if self.pendingWrites == 0, cfg != self.config { self.config = cfg }
            }
        }
        monitor.onEvent = { [weak self] e in self?.notify(e); self?.bridge?.event(e) }
        monitor.start()
        bridge?.systemWatch = system
        system.onSample = { [weak self] h in
            self?.bridge?.systemSample(h)
            DispatchQueue.main.async { self?.health = h }
        }
        system.onAlert = { [weak self] level, h in
            self?.post(title: SystemText.title(level, reasons: h.reasons), body: SystemText.body(reasons: h.reasons, apps: h.apps))
            self?.bridge?.systemAlert(level, h)
        }
        // Quitting can take 30 s; keep it off the sampling queue.
        system.onAutoAct = { [weak self] h in DispatchQueue.global(qos: .userInitiated).async { self?.autoAct(h) } }
        system.start()
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

    private func post(title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // MARK: System health

    /// Runs a system action off the main thread; `done` gets (ok, message) on main.
    func runSystem(_ a: SystemAction, done: @escaping (Bool, String) -> Void) {
        let snap = snapshot, apps = health?.apps ?? []
        DispatchQueue.global(qos: .userInitiated).async { [system] in
            let r = SystemActions.run(a, snapshot: snap, apps: apps)
            if case .clean = a { system.refreshCleanable() }
            DispatchQueue.main.async { done(r.ok, r.message) }
        }
    }

    /// The Mac stayed critical: carry out the auto-act settings once, then say what was done.
    private func autoAct(_ h: SystemHealth) {
        let cfg = monitor.config.system.auto
        let snap = DispatchQueue.main.sync { snapshot }
        var done: [String] = []
        if cfg.closeIdleClaude { done.append(SystemActions.run(.closeIdleClaude, snapshot: snap, apps: h.apps).message) }
        for id in cfg.quitApps {
            let r = SystemActions.run(.quitApp(id), snapshot: snap, apps: h.apps, force: cfg.forceIfStuck)
            if !r.message.hasSuffix("isn't running") { done.append(r.message) }
        }
        if !cfg.cleanTargets.isEmpty, h.reasons.contains(where: { $0.hasPrefix("disk ") }) {
            done.append(SystemActions.run(.clean(cfg.cleanTargets), snapshot: snap, apps: h.apps).message)
            system.refreshCleanable()
        }
        guard !done.isEmpty else { return }
        let body = done.joined(separator: " · ")
        bridge?.server.audit.append(device: "auto", command: "auto-act", target: nil, result: "done", reason: body)
        post(title: "Session Watch acted: Mac was critical", body: body)
        bridge?.pushSystem(title: "Session Watch acted: Mac was critical", body: body)
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

    // MARK: Config

    /// Applies `change` here at once, then saves config.json through the Monitor (which re-reads
    /// the file first, writes it atomically and starts using it).
    func updateConfig(_ change: @escaping (inout Config) -> Void) {
        var c = config
        change(&c)
        config = c
        pendingWrites += 1
        monitor.updateConfig(change) { [weak self] r in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingWrites -= 1
                switch r {
                case .success(let saved):
                    self.configError = nil
                    if self.pendingWrites == 0 { self.config = saved }
                case .failure(let e):
                    self.configError = e.localizedDescription
                    if self.pendingWrites == 0 { self.config = self.monitor.config }
                }
            }
        }
    }

    /// At least one of the menu bar item and the Dock icon stays on.
    func setShowInMenuBar(_ on: Bool) {
        guard on != config.showInMenuBar else { return }
        updateConfig { $0.showInMenuBar = on; if !on { $0.showInDock = true } }
    }

    func setShowInDock(_ on: Bool) {
        guard on != config.showInDock else { return }
        updateConfig { $0.showInDock = on; if !on { $0.showInMenuBar = true } }
    }

    // MARK: Windows

    /// `.regular` (Dock, Cmd-Tab, menu bar) or `.accessory` (menu bar item only). Overrides LSUIElement.
    func applyActivationPolicy() {
        guard let app = NSApp else { return }
        let want: NSApplication.ActivationPolicy = config.showInDock ? .regular : .accessory
        guard app.activationPolicy() != want else { return }
        let wasVisible = mainWindow?.isVisible ?? false
        app.setActivationPolicy(want)
        // Leaving the Dock deactivates the app; keep the window in front.
        if wasVisible { DispatchQueue.main.async { self.showMain() } }
    }

    var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(MainWindow.id) == true && $0.canBecomeMain }
    }

    /// Opens (or fronts) the main window, optionally on a section. Works in `.accessory` mode too.
    func showMain(_ section: MainSection? = nil) {
        if let section { self.section = section }
        if let w = mainWindow, w.isVisible {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else {
            openWindowAction?(id: MainWindow.id)
        }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { self.mainWindow?.makeKeyAndOrderFront(nil) }
    }

    func quit() { NSApp.terminate(nil) }   // AppDelegate.applicationWillTerminate stops the bridge and monitor

    func shutdown() { bridge?.stop(); monitor.stop() }

    /// Quits and opens the app again (bridge port / on-off changes need a fresh process).
    func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundleURL.path]
        try? p.run()
        quit()
    }

    /// Retry every waiting chat of an account (all its member profiles).
    func retryAll(_ profileIds: [String]) { request(profileIds.map { .profile($0) }) }

    /// Send "continue" to one queued chat now, even if its account is still limited.
    func retryNow(itemId: String) { request([.item(itemId)]) }

    func dismiss(_ id: String) { request([.dismiss(id)]) }

    /// Runs queue actions here, or forwards them to the process that owns the retry engine.
    private func request(_ rs: [RetryRequest]) {
        monitor.perform { m in
            for r in rs { m.engine.request(r) }
            m.refreshNow()
        }
    }

    // MARK: Moving chats

    func profile(_ id: String) -> Profile? { snapshot?.profiles.first { $0.id == id } }

    func source(of s: SessionInfo) -> ChatLocation? {
        let parts = s.folder.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        let id = s.profileId + "/" + parts[0] + "/" + parts[1]
        return snapshot?.locations.first { $0.id == id }
            ?? ChatLocation(profileId: s.profileId, accountUuid: parts[0], orgUuid: parts[1])
    }

    func destinations(from loc: ChatLocation) -> [ChatLocation] {
        SessionMover.destinations(for: loc, in: snapshot?.locations ?? [])
    }

    func pendingMove(for sessionId: String) -> PendingMove? {
        snapshot?.moves.first { $0.sessionId == sessionId && $0.status == .pending }
    }

    /// Why a chat can't move right now, or nil.
    func moveBlocker(_ sessionId: String) -> String? {
        switch snapshot?.accounts.flatMap(\.sessions).first(where: { $0.id == sessionId })?.activity {
        case .working?: return "Can't move while it's working"
        case .waiting?: return "Can't move while it needs you"
        default: return pendingMove(for: sessionId) != nil ? "Already moving" : nil
        }
    }

    func move(_ chats: [(id: String, title: String, from: ChatLocation)], to: ChatLocation) {
        let queued = chats.compactMap { monitor.requestMove(sessionId: $0.id, title: $0.title, from: $0.from, to: to) }
        if !queued.isEmpty { askRestart(queued) }
    }

    func undoMove(_ id: String) {
        if let m = monitor.undoMove(id) { askRestart([m]) }
    }

    func cancelMove(_ id: String) { monitor.cancelMove(id) }

    func askRestart(_ queued: [PendingMove]) {
        let names = Array(Set(queued.flatMap { [$0.from.profileName, $0.to.profileName] })).sorted()
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = queued.count == 1 ? "Move “\(queued[0].title)” to \(queued[0].to.label)?"
                                          : "Move \(queued.count) chats to \(queued[0].to.label)?"
        a.informativeText = "\(names.joined(separator: " and ")) need to restart. Session Watch quits them, "
            + "moves the chat and opens them again. With Later, the move runs the next time both are closed."
        a.addButton(withTitle: "Restart now")
        a.addButton(withTitle: "Later")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let windows = Set(queued.flatMap { [$0.from.profileId, $0.to.profileId] })
        let busy = (snapshot?.accounts.flatMap(\.sessions) ?? [])
            .filter { windows.contains($0.info.profileId) && $0.activity == .working }
        if !busy.isEmpty {
            let w = NSAlert()
            w.messageText = busy.count == 1 ? "1 chat is still working" : "\(busy.count) chats are still working"
            w.informativeText = busy.prefix(5).map { "• " + $0.info.title }.joined(separator: "\n")
                + "\n\nQuitting stops them mid-reply."
            w.addButton(withTitle: "Quit anyway")
            w.addButton(withTitle: "Later")
            guard w.runModal() == .alertFirstButtonReturn else { return }
        }
        DispatchQueue.global(qos: .userInitiated).async { [monitor] in
            let r = monitor.restartAndRunMoves(only: Set(queued.map(\.id)))
            func notify(_ title: String, _ body: String) {
                let c = UNMutableNotificationContent()
                c.title = title
                c.body = body
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
            }
            for p in r.stuck { notify("\(p.name) didn't quit", "The move runs once you close it.") }
            for m in r.waiting { notify("Move waiting", m.waitingMessage) }
        }
    }
}

// MARK: - Style

enum Theme {
    static let clay = Color(red: 0.851, green: 0.467, blue: 0.341)
    static let mono = Font.system(size: 11.5, design: .monospaced)
    static let monoSmall = Font.system(size: 10.5, design: .monospaced)
    static let green = Color(red: 0.47, green: 0.75, blue: 0.47)
    static let yellow = Color(red: 0.86, green: 0.70, blue: 0.35)
    static let red = Color(red: 0.90, green: 0.40, blue: 0.40)
    static let panel = Color.primary.opacity(0.04)
    static let hairline = Color.primary.opacity(0.12)

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
    var account: String? = nil     // shown in the main window's all-accounts list
    var lastActive = false         // show "3m ago"
    let open: () -> Void
    @EnvironmentObject var model: WatchModel
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("▸").foregroundStyle(Theme.clay)
                Text(s.info.title).lineLimit(1).truncationMode(.tail)
                Text("· " + (s.info.cwd as NSString).lastPathComponent)
                    .foregroundStyle(.secondary).lineLimit(1)
                if let account { Text("· " + account).foregroundStyle(.tertiary).lineLimit(1) }
                Spacer(minLength: 4)
                if lastActive { Text(Fmt.ago(s.info.lastActivityAt)).foregroundStyle(.tertiary).lineLimit(1) }
                if let p = model.pendingMove(for: s.id) {
                    Text("→ " + p.to.profileName + " · waiting for restart").foregroundStyle(Theme.clay).lineLimit(1)
                    Button { model.cancelMove(p.id) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary).help("Cancel move")
                } else {
                    if !s.tasks.isEmpty { Text(taskSummary).foregroundStyle(.secondary) }
                    Text(activity.0).foregroundStyle(activity.1)
                    moveMenu.opacity(hover ? 1 : 0)
                }
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

    @ViewBuilder var moveMenu: some View {
        let from = model.source(of: s.info)
        let targets = from.map { model.destinations(from: $0) } ?? []
        let blocker = model.moveBlocker(s.id) ?? (targets.isEmpty ? "No other window to move to" : nil)
        Menu {
            ForEach(targets) { t in
                Button(t.label) { if let from { model.move([(id: s.id, title: s.info.title, from: from)], to: t) } }
            }
        } label: { Image(systemName: "arrow.left.arrow.right") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(blocker != nil)
        .help(blocker ?? "Move to another window")
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
    var queue: [RetryItem] = []   // this account's retry items
    var maxSessions = 4           // chats listed under the card (the main window shows more)
    @EnvironmentObject var model: WatchModel
    @Environment(\.openWindow) private var openWindow

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
                Button("All chats…") {
                    model.chatsProfile = a.profile.id
                    openWindow(id: "chats")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.link)
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
            QueueBlock(title: "Retry queue", queue: queue, now: now,
                       retryAll: { model.retryAll(a.memberProfileIds) })
        }
        .padding(.vertical, 8)
    }

    var badge: String {
        var b = Theme.label(a.state)
        if a.state == .limited, let u = a.limitedUntil { b += " · " + Fmt.time(u, now: now) }
        return b
    }

    var visibleSessions: [SessionStatus] {
        let active = a.sessions.filter { $0.activity != .idle }.prefix(maxSessions)
        let idle = a.sessions.filter { $0.activity == .idle }.prefix(max(0, 2 - active.count))
        return Array(active) + Array(idle)
    }
}

/// Retry items of one account (or of no known account), shown inside its card.
struct QueueBlock: View {
    let title: String
    let queue: [RetryItem]
    let now: Date
    var showProfile = false
    var recentLimit = 2
    var retryAll: (() -> Void)?
    @EnvironmentObject var model: WatchModel

    var body: some View {
        let active = queue.filter { $0.isActive }
        let recent = Array(queue.filter { !$0.isActive }.suffix(recentLimit))
        let waiting = active.filter { $0.status == .waiting }.count
        if !active.isEmpty || !recent.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                if !title.isEmpty || (waiting >= 2 && retryAll != nil) {
                    HStack {
                        Text(title).foregroundStyle(.secondary)
                        Spacer()
                        if waiting >= 2, let retryAll {
                            Button("Retry all", action: retryAll).buttonStyle(.link)
                                .help("Send “continue” to all \(waiting) waiting chats now")
                        }
                    }
                    .padding(.horizontal, 4)
                }
                ForEach(active + recent) { it in
                    QueueRow(it: it, now: now,
                             profile: showProfile ? (model.profile(it.profileId)?.name ?? it.profileId) : nil)
                }
            }
            .font(Theme.monoSmall)
            .padding(.top, 2)
        }
    }
}

struct QueueRow: View {
    let it: RetryItem
    let now: Date
    var profile: String?      // shown when the item isn't under an account card
    @EnvironmentObject var model: WatchModel
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Text(mark.0).foregroundStyle(mark.1)
            if let profile {
                Text(profile).foregroundStyle(.secondary).frame(width: 90, alignment: .leading).lineLimit(1)
            }
            Text(it.title).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            Text(detail).foregroundStyle(.secondary).lineLimit(1)
            if it.isActive || it.status == .failed {
                Button("Retry now") { model.retryNow(itemId: it.id) }
                    .buttonStyle(.link)
                    .disabled(it.status == .running || it.status == .verifying)
                    .help(it.status == .failed ? "Try again from scratch"
                          : "Retry now, even if the limit hasn't reset")
            }
            Button { model.dismiss(it.id) } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.tertiary).help("Remove from queue")
        }
        .font(Theme.monoSmall)
        .padding(.vertical, 1).padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 4).fill(hover ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { model.open(sessionId: it.sessionId, profileId: it.profileId) }
        .help(it.note ?? "Open in Claude")
    }

    var mark: (String, Color) {
        switch it.status {
        case .waiting, .running, .verifying: ("⟳", Theme.clay)
        case .done: ("✓", Theme.green)
        case .failed: ("✗", Theme.red)
        case .resolved: ("–", .secondary)
        }
    }

    var detail: String {
        switch it.status {
        case .verifying: return "checking reply…"
        case .waiting:
            guard let r = it.resetsAt, r > .distantPast else { return "due" }
            return r > now ? "in " + Fmt.duration(r.timeIntervalSince(now)) : "due"
        case .running: return it.status.rawValue
        default: return it.note ?? ""
        }
    }
}

extension RetryItem {
    var isActive: Bool { [.waiting, .running, .verifying].contains(status) }
}

struct PopoverView: View {
    @EnvironmentObject var model: WatchModel
    @Environment(\.openWindow) private var openWindow
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
                        AccountCard(a: a, now: ctx.date, queue: s.queue.filter { a.memberProfileIds.contains($0.profileId) })
                    }
                    Divider()
                    let other = s.queue.filter { it in !s.accounts.contains { $0.memberProfileIds.contains(it.profileId) } }
                    if !other.isEmpty {
                        QueueBlock(title: "Other", queue: other, now: ctx.date, showProfile: true).padding(.vertical, 4)
                    }
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
                    Button("Open Session Watch") { model.showMain() }
                        .help("Open the main window")
                    Button(showStats ? "Hide stats" : "Stats") { showStats.toggle() }
                        .help("UI vs CLI retry stats")
                    Button("Config") { NSWorkspace.shared.open(Paths.config) }
                    Button("Logs") { NSWorkspace.shared.open(Paths.support) }
                    Button("iPhone…") { model.showMain(.iphone) }
                        .help("Pair the Session Watch iPhone app")
                    Spacer()
                    Button("Quit") { model.quit() }
                }
                .buttonStyle(.link).font(Theme.monoSmall).padding(.top, 6)
            }
            .padding(12)
            .frame(width: 440)
        }
        .capturesOpenWindow(model)
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

/// Lets AppKit callbacks open SwiftUI windows: stores the scene's `openWindow` in the model.
private struct CaptureOpenWindow: ViewModifier {
    let model: WatchModel
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content.onAppear { model.openWindowAction = openWindow }
    }
}

extension View {
    func capturesOpenWindow(_ model: WatchModel) -> some View { modifier(CaptureOpenWindow(model: model)) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: WatchModel { .shared }

    func applicationWillFinishLaunching(_ n: Notification) {
        // LSUIElement stays in Info.plist (no Dock flash when the Dock icon is off); this overrides it.
        NSApp.setActivationPolicy(model.config.showInDock ? .regular : .accessory)
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        #if DEBUG
        DevSnapshot.install()
        #endif
        LoginItem.registerOnFirstLaunch()
        // SwiftUI opens the main window as the first scene; make sure it's in front, also as an accessory app.
        DispatchQueue.main.async { self.model.showMain() }
    }

    /// Finder, Spotlight, Dock click or `open` while running: show the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.showMain()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ n: Notification) { model.shutdown() }
}

@main
struct ClaudeWatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = WatchModel.shared

    var body: some Scene {
        Window("Session Watch", id: MainWindow.id) {
            MainWindow().environmentObject(model)
        }
        .defaultSize(width: 1040, height: 720)

        MenuBarExtra(isInserted: Binding(get: { model.config.showInMenuBar },
                                         set: { model.setShowInMenuBar($0) })) {
            PopoverView().environmentObject(model)
        } label: {
            Text(model.label).monospacedDigit().capturesOpenWindow(model)
        }
        .menuBarExtraStyle(.window)

        Window("All chats", id: "chats") {
            ChatsWindow().environmentObject(model)
        }
        .defaultSize(width: 820, height: 560)

        Settings {
            SettingsView().environmentObject(model).frame(width: 560, height: 640)
        }
    }
}
