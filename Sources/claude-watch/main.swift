import Foundation
import WatchCore
import WatchBridge

// MARK: - ANSI helpers (Claude Code palette)

enum A {
    static var color = isatty(STDOUT_FILENO) == 1 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    static func c(_ code: String, _ s: String) -> String { color ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
    static func clay(_ s: String) -> String { c("38;2;217;119;87", s) }
    static func dim(_ s: String) -> String { c("2", s) }
    static func bold(_ s: String) -> String { c("1", s) }
    static func green(_ s: String) -> String { c("38;2;120;190;120", s) }
    static func yellow(_ s: String) -> String { c("38;2;220;180;90", s) }
    static func red(_ s: String) -> String { c("38;2;230;100;100", s) }

    static func visibleWidth(_ s: String) -> Int {
        var n = 0, esc = false
        for ch in s.unicodeScalars {
            if esc { if ch == "m" { esc = false }; continue }
            if ch == "\u{1B}" { esc = true; continue }
            n += 1
        }
        return n
    }
    static func pad(_ s: String, _ w: Int) -> String { s + String(repeating: " ", count: max(0, w - visibleWidth(s))) }
    static func trunc(_ s: String, _ w: Int) -> String { s.count > w ? String(s.prefix(max(1, w - 1))) + "…" : s }
}

func termWidth() -> Int {
    var ws = winsize()
    if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 20 { return Int(ws.ws_col) }
    return 80
}

func bar(_ pct: Double?, width: Int = 20) -> String {
    guard let pct else { return A.dim(String(repeating: "·", count: width)) }
    let filled = Int((min(100, max(0, pct)) / 100 * Double(width)).rounded())
    let body = String(repeating: "█", count: filled)
    let rest = String(repeating: "░", count: width - filled)
    let colored = pct >= 90 ? A.red(body) : pct >= 70 ? A.yellow(body) : A.clay(body)
    return colored + A.dim(rest)
}

func stateBadge(_ s: AccountState) -> String {
    switch s {
    case .free: return A.green("free")
    case .working: return A.yellow("working")
    case .limited: return A.red("limited")
    case .offline: return A.dim("not running")
    }
}

func dot(_ s: AccountState) -> String {
    switch s {
    case .free: return A.green("●")
    case .working: return A.clay("●")
    case .limited: return A.red("●")
    case .offline: return A.dim("○")
    }
}

func taskSummary(_ tasks: [TaskItem]) -> String {
    guard !tasks.isEmpty else { return "" }
    let done = tasks.filter { $0.status == .completed }.count
    let doing = tasks.filter { $0.status == .in_progress }.count
    let todo = tasks.count - done - doing
    return A.dim("☑\(done) ◐\(doing) ☐\(todo)")
}

func activityLabel(_ a: SessionStatus.Activity) -> String {
    switch a {
    case .working: return A.yellow("working")
    case .waiting: return A.clay("needs you")
    case .failed: return A.red("hit limit")
    case .idle: return A.dim("idle")
    }
}

// MARK: - Rendering

func queueIsActive(_ it: RetryItem) -> Bool { [.waiting, .running, .verifying].contains(it.status) }

/// Active items plus the last few finished ones, one line each. `name` labels items outside an account.
func queueLines(_ items: [RetryItem], recentCount: Int, width w: Int, now: Date,
                name: ((RetryItem) -> String)? = nil) -> [String] {
    var out: [String] = []
    for it in items.filter(queueIsActive) {
        var when = ""
        if it.status == .waiting, let r = it.resetsAt { when = r > now ? "in " + Fmt.duration(r.timeIntervalSince(now)) : "due" }
        else if it.status == .verifying { when = "checking reply…" }
        let label = name.map { A.pad(A.trunc($0(it), 16), 17) } ?? ""
        out.append("  " + A.clay("⟳") + " " + label + A.trunc(it.title, max(10, w - 44))
                   + "  " + A.dim(when) + (it.note.map { A.dim(" · " + $0) } ?? ""))
    }
    for it in items.filter({ !queueIsActive($0) }).suffix(recentCount) {
        let mark = it.status == .done ? A.green("✓") : it.status == .failed ? A.red("✗") : A.dim("–")
        let label = name.map { A.pad(A.trunc($0(it), 16), 17) } ?? ""
        out.append("  " + mark + " " + A.dim(label + A.trunc(it.title, max(10, w - 30)) + (it.note.map { " · " + $0 } ?? "")))
    }
    return out
}

func render(_ snap: Snapshot, width: Int, detailed: Bool = true) -> String {
    let now = Date()
    var out: [String] = []
    let w = min(width, 110)
    let header = A.clay("✻") + " " + A.bold("claude-watch")
    let right = A.dim(Fmt.time(now) + " · " + (snap.engineOwner ? "retry engine: here" : "retry engine: other process"))
    out.append(A.pad(header, w - A.visibleWidth(right)) + right)
    out.append("")

    for a in snap.accounts {
        var badge = stateBadge(a.state)
        if a.state == .limited, let u = a.limitedUntil {
            badge += A.dim(" until " + Fmt.time(u, now: now))
        }
        let extra = a.profile.id + (a.alsoOpenIn.isEmpty ? "" : " + " + a.alsoOpenIn.joined(separator: ", "))
        let room = w - A.visibleWidth(badge) - a.profile.name.count - 6
        let title = dot(a.state) + " " + A.bold(a.profile.name) + (room > 4 ? A.dim(" · " + A.trunc(extra, room)) : "")
        out.append(A.pad(title, w - A.visibleWidth(badge)) + badge)
        for (label, f) in [("5h", a.fiveHour), ("7d", a.weekly)] {
            let pct = A.pad(Fmt.percent(f.percent), 5)
            var fc = Fmt.forecast(f, pace: a.tokensPerHourNow, now: now)
            if let h = f.hitsAt, !f.resetsFirst, h.timeIntervalSince(now) < 3600, (f.percent ?? 0) < 100 { fc = A.clay(fc) }
            else { fc = A.dim(fc) }
            let age = f.sampleAt.map { A.dim("  sampled " + Fmt.ago($0, now: now)) } ?? ""
            out.append("  " + A.dim(label) + "  " + bar(f.percent) + "  " + pct + " " + fc + (detailed ? age : ""))
        }
        let pace = a.tokensPerHourNow > 0 ? " · pace " + Fmt.tokens(a.tokensPerHourNow) + "/h" : ""
        out.append("  " + A.dim("tokens 5h " + Fmt.tokens(a.tokens5h) + " · 7d " + Fmt.tokens(a.tokens7d) + pace
                              + " · retry " + a.retryMode.rawValue))
        let shown = a.sessions.filter { $0.activity != .idle }.prefix(4)
        let idle = a.sessions.filter { $0.activity == .idle }.prefix(max(0, 2 - shown.count))
        for s in Array(shown) + Array(idle) {
            let folder = (s.info.cwd as NSString).lastPathComponent
            let lhs = "  " + A.clay("▸") + " " + A.trunc(s.info.title, max(10, w - 44)) + A.dim(" · " + A.trunc(folder, 18))
            let rhs = activityLabel(s.activity) + (s.tasks.isEmpty ? "" : "  " + taskSummary(s.tasks))
            out.append(A.pad(lhs, w - A.visibleWidth(rhs)) + rhs)
            if let t = s.tasks.first(where: { $0.status == .in_progress }) {
                out.append("      " + A.dim("◐ " + A.trunc(t.activeForm ?? t.subject, w - 10)))
            }
            if s.activity == .failed, let hit = s.tail.lastRateLimit {
                out.append("      " + A.dim(A.trunc(hit.text, w - 10)))
            }
        }
        let queued = queueLines(snap.queue.filter { a.memberProfileIds.contains($0.profileId) },
                                recentCount: 2, width: w, now: now)
        if !queued.isEmpty { out.append("  " + A.dim("retry queue")); out += queued }
        out.append("")
    }

    // Items whose profile isn't under any account, so nothing disappears.
    let other = snap.queue.filter { it in !snap.accounts.contains { $0.memberProfileIds.contains(it.profileId) } }
    let lines = queueLines(other, recentCount: 3, width: w, now: now) { it in
        snap.profiles.first { $0.id == it.profileId }?.name ?? it.profileId
    }
    if !lines.isEmpty {
        out.append(A.bold("Retry queue") + A.dim(" · other profiles"))
        out += lines
        out.append("")
    }
    return out.joined(separator: "\n")
}

// MARK: - Commands

let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("""
    \(A.clay("✻")) claude-watch — monitor your Claude accounts

      claude-watch                     live dashboard (q quit, r refresh, R retry due chats now)
      claude-watch status [--json]     one-shot snapshot
      claude-watch queue [--stats]     retry queue, or UI-vs-CLI success stats
      claude-watch retry [profile]     retry waiting chats now (all or one profile), even if still limited
      claude-watch retry --item <chat> retry one queued chat now (session id local_…, see `queue`);
                                       also restarts a chat that gave up
      claude-watch probe [profile]     dry-run the UI retry path (opens a chat, types nothing)
      claude-watch mode <profile> <ui|cli|off>
      claude-watch set-token <profile> store a `claude setup-token` token for CLI retries
      claude-watch profiles            list discovered profiles
      claude-watch move <chat> --to <profile>[:<org>] [--from <profile>] [--now [--force]]
                                       move a chat (id or title words) to another window
      claude-watch moves [--undo <id> [--now] | --cancel <id> | --now]
      claude-watch set-apns-key <AuthKey.p8> --key-id <id> --team-id <id> [--topic <bundle id>]
                                       enable iPhone push notifications (key from developer.apple.com)
      claude-watch probe-prompt <chat> dry-run answering a prompt: lists the window's buttons, presses nothing
      claude-watch prompt-tool --socket <path> --session <id>
                                       (internal) permission prompt MCP server for iPhone replies
    """)
    exit(0)
}

func notify(_ title: String, _ body: String) {
    let esc: (String) -> String = { $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""]
    try? p.run()
}

/// Quits the windows of these moves, runs them, reopens the windows, and prints the outcome.
func restartAndRun(_ moves: [PendingMove]) {
    let monitor = Monitor(ownEngine: false)
    let snap = monitor.pollOnce()
    let windows = Set(moves.flatMap { [$0.from.profileId, $0.to.profileId] })
    let busy = snap.accounts.flatMap(\.sessions).filter { windows.contains($0.info.profileId) && $0.activity == .working }
    if !busy.isEmpty && !args.contains("--force") {
        print(A.yellow("Not restarting: \(busy.count) chat\(busy.count == 1 ? " is" : "s are") still working:"))
        for s in busy.prefix(5) { print("  " + A.clay("▸") + " " + s.info.title) }
        print(A.dim("The move stays queued and runs once both windows are closed. Add --force to quit them anyway."))
        return
    }
    print("Restarting \(Set(moves.flatMap { [$0.from.profileName, $0.to.profileName] }).sorted().joined(separator: " and "))…")
    let r = monitor.restartAndRunMoves(only: Set(moves.map(\.id)))
    for s in r.stuck { print(A.yellow("\(s.name) didn't quit; the move runs once it's closed.")) }
    for w in r.waiting { print(A.yellow(w.waitingMessage)) }
    for f in r.finished {
        print(f.status == .done ? A.green("✓ moved “\(f.title)”") : A.red("✗ \(f.title): \(f.note ?? f.status.rawValue)"))
    }
}

func describe(_ e: WatchEvent) -> (String, String) {
    switch e {
    case .accountFree(let p): return ("\(p.name) is free", "Nothing running. Ready for the next task.")
    case .limitReset(let p): return ("\(p.name) limit reset", "The account can be used again.")
    case .limited(let p, let k, let u):
        let kind = k == .weekly ? "weekly" : k == .fiveHour ? "5-hour" : "usage"
        return ("\(p.name) hit its \(kind) limit", u.map { "Resets " + Fmt.time($0) } ?? "")
    case .capSoon(let p, let k, let at):
        return ("\(p.name) nearing \(k == .weekly ? "weekly" : "5-hour") limit",
                "At this pace it hits the cap in ~\(Fmt.duration(at.timeIntervalSinceNow)).")
    case .retry(_, let msg): return ("claude-watch", msg)
    case .moved(let m):
        return m.status == .done ? ("Moved “\(m.title)”", "Now in \(m.to.label).")
                                 : ("Couldn't move “\(m.title)”", m.note ?? m.status.rawValue)
    }
}

switch args.first {
case "-h", "--help", "help":
    usage()

case "status":
    let m = Monitor(ownEngine: false)
    let snap = m.pollOnce()
    if args.contains("--json") {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        FileHandle.standardOutput.write(try! enc.encode(snap))
        print()
    } else {
        print(render(snap, width: termWidth()))
    }

case "profiles":
    for p in ProfileDiscovery.discover(config: Config.load()) {
        print("\(A.pad(A.bold(p.id), 14)) \(A.pad(p.name, 22)) \(A.dim(p.dataDir.path))"
              + (TokenStore.get(p.id) != nil ? A.green("  cli token ✓") : ""))
    }

case "queue":
    if args.contains("--stats") {
        let stats = RetryEngine.stats()
        if stats.isEmpty { print(A.dim("No retries logged yet.")) }
        for s in stats {
            let rate = s.sent > 0 ? Int(Double(s.verified) / Double(s.sent) * 100) : 0
            print("\(A.bold(A.pad(s.mode.rawValue.uppercased(), 4))) sent \(s.sent) · resumed \(s.verified) (\(rate)%) · "
                  + "no reply \(s.noResponse) · re-limited \(s.relimited) · send errors \(s.sendFailed)"
                  + (s.avgLatency.map { " · avg reply \(Int($0))s" } ?? ""))
        }
    } else {
        let snap = Monitor(ownEngine: false).pollOnce()
        if snap.queue.isEmpty { print(A.dim("Queue is empty.")) }
        for it in snap.queue {
            print("\(A.pad(it.status.rawValue, 10)) \(A.pad(it.profileId, 11)) \(A.trunc(it.title, 50))"
                  + A.dim(it.resetsAt.flatMap { $0 > .distantPast ? " · resets " + Fmt.time($0) : " · due now" } ?? "")
                  + A.dim(it.note.map { " · " + $0 } ?? "") + A.dim("  " + it.sessionId))
        }
    }

case "probe":
    // Opens the most recent chat of a profile in its window and checks the message box. Types nothing.
    let cfg = Config.load()
    let profiles = ProfileDiscovery.discover(config: cfg)
    guard let p = profiles.first(where: { $0.id == (args.dropFirst().first ?? "") }) ?? profiles.first(where: { !$0.isDefault }) else { usage() }
    guard let s = SessionIndex().sessions(for: p).first(where: { !$0.isArchived }) else { print("No chats in \(p.id)"); exit(1) }
    print("Probing \(p.name) with “\(s.title)”…")
    print(UIRetry.probe(session: s, profile: p))

case "retry":
    if let i = args.firstIndex(of: "--item") {
        guard i + 1 < args.count, !args[i + 1].isEmpty else { usage() }
        let key = args[i + 1]
        let q = Monitor(ownEngine: false).engine.items
        guard let it = q.last(where: { ($0.sessionId == key || $0.id == key) && [.waiting, .failed].contains($0.status) })
        else { print("No waiting or failed chat \(key) in the queue (see `claude-watch queue`)."); exit(1) }
        RetryRequest.append(.item(it.sessionId))
        print("Requested a retry of “\(it.title)”. The retry engine will pick it up on its next poll.")
    } else {
        RetryRequest.append(args.dropFirst().first.map { .profile($0) } ?? .all)
        print("Requested. The retry engine will pick it up on its next poll.")
    }

case "mode":
    guard args.count == 3, let mode = RetryMode(rawValue: args[2]) else { usage() }
    var cfg = Config.load()
    var pc = cfg.profiles[args[1]] ?? ProfileConfig()
    pc.retryMode = mode
    cfg.profiles[args[1]] = pc
    try? cfg.save()
    print("\(args[1]) retry mode: \(mode.rawValue)")

case "set-token":
    guard args.count == 2 else { usage() }
    print("Paste the token from `claude setup-token` (signed in as the \(args[1]) account), then press Return:")
    guard let raw = String(validatingUTF8: getpass("")), !raw.isEmpty else { print("Nothing stored."); exit(1) }
    print(TokenStore.set(raw.trimmingCharacters(in: .whitespacesAndNewlines), for: args[1])
          ? A.green("Stored in Keychain.") : A.red("Couldn't write to Keychain."))

case "prompt-tool":
    // Started by `claude` itself during an iPhone reply; speaks MCP on stdin/stdout.
    func flag(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    guard let socket = flag("--socket"), let session = flag("--session") else { usage() }
    PromptTool.serve(socketPath: socket, sessionId: session)

case "set-apns-key":
    func flag(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    guard args.count >= 2, let keyId = flag("--key-id"), let teamId = flag("--team-id"),
          let pem = try? String(contentsOfFile: (args[1] as NSString).expandingTildeInPath, encoding: .utf8) else { usage() }
    let key = APNsKey(keyId: keyId, teamId: teamId, pem: pem, topic: flag("--topic") ?? "dev.lajward.SessionWatch")
    do { _ = try key.signingKey() } catch { print(A.red("That file isn't an APNs .p8 key: \(error)")); exit(1) }
    print(key.save() ? A.green("Stored in Keychain. Restart ClaudeWatch to start sending pushes.") : A.red("Couldn't write to Keychain."))

case "probe-prompt":
    let query = args.dropFirst().joined(separator: " ")
    let cfg = Config.load()
    let profiles = ProfileDiscovery.discover(config: cfg)
    let index = SessionIndex()
    let all = profiles.flatMap { index.sessions(for: $0) }
    guard !query.isEmpty, let s = all.first(where: { $0.id == query || $0.cliSessionId == query })
            ?? all.first(where: { $0.title.localizedCaseInsensitiveContains(query) }),
          let p = profiles.first(where: { $0.id == s.profileId }) else { print("No chat matches “\(query)”"); exit(1) }
    print("Opening “\(s.title)” in \(p.name)…")
    switch DesktopActions.answer(decision: .allow, session: s, profile: p, dryRun: true) {
    case .success(let m): print(m)
    case .failure(let e): print(A.red(e.message)); exit(1)
    }

case "move":
    guard let toAt = args.firstIndex(of: "--to"), toAt + 1 < args.count else { usage() }
    let firstFlag = args.dropFirst().firstIndex { $0.hasPrefix("--") } ?? args.count
    let query = args[1..<firstFlag].joined(separator: " ")
    guard !query.isEmpty else { usage() }
    let fromArg = args.firstIndex(of: "--from").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    let cfg = Config.load()
    let profiles = ProfileDiscovery.discover(config: cfg)
    let locs = SessionMover.locations(profiles: profiles, config: cfg)
    // "2" matches claude-2-…; a full id matches itself.
    func profileMatches(_ id: String, _ arg: String) -> Bool { id == arg || id.hasPrefix("claude-\(arg)-") }
    let sources = locs.filter { l in fromArg.map { profileMatches(l.profileId, $0) } ?? (l.profileId != "default") }
    let matches = sources.flatMap { l -> [ChatRecord] in
        guard let p = profiles.first(where: { $0.id == l.profileId }) else { return [] }
        return SessionMover.listChats(at: l, profile: p)
            .filter { $0.id == query || $0.title.localizedCaseInsensitiveContains(query) }
    }
    guard !matches.isEmpty else { print("No chat matches “\(query)”."); exit(1) }
    guard matches.count == 1 else {
        print("Several chats match. Use the chat id (and --from <profile>):")
        for c in matches.prefix(20) { print("  \(c.id)  \(A.pad(A.trunc(c.title, 40), 41)) \(A.dim(c.location.label))") }
        exit(1)
    }
    let chat = matches[0]
    let target = args[toAt + 1].split(separator: ":", maxSplits: 1).map(String.init)
    let options = SessionMover.destinations(for: chat.location, in: locs)
    let dests = options.filter { d in
        profileMatches(d.profileId, target[0]) && (target.count < 2 || d.orgUuid.hasPrefix(target[1]))
    }
    guard dests.count == 1 else {
        print(dests.isEmpty ? "No destination matches “\(args[toAt + 1])”. Options:" : "Pick one with <profile>:<org>:")
        for d in dests.isEmpty ? options : dests { print("  \(d.profileId):\(d.orgUuid.prefix(8))  \(A.dim(d.label))") }
        exit(1)
    }
    guard let m = MoveStore().add(sessionId: chat.id, title: chat.title, from: chat.location, to: dests[0]) else {
        print("Couldn't queue it: the chat already has a pending move (see `claude-watch moves`), or moves.json couldn't be saved.")
        exit(1)
    }
    print("Queued \(m.id): “\(chat.title)”  \(chat.location.label) → \(dests[0].label)")
    if args.contains("--now") {
        restartAndRun([m])
    } else {
        print(A.dim("It runs once both windows are closed (the Session Watch app does it). Add --now to restart them now."))
    }

case "moves":
    let store = MoveStore()
    if let i = args.firstIndex(of: "--undo"), i + 1 < args.count {
        guard let m = store.undo(moveId: args[i + 1]) else { print("No finished move \(args[i + 1]), or it couldn't be queued."); exit(1) }
        print("Queued undo \(m.id): “\(m.title)”  \(m.from.label) → \(m.to.label).")
        if args.contains("--now") { restartAndRun([m]) } else { print(A.dim("Runs once both windows are closed. Add --now to restart them now.")) }
    } else if let i = args.firstIndex(of: "--cancel"), i + 1 < args.count {
        store.cancel(id: args[i + 1])
        print("Cancelled \(args[i + 1]).")
    } else if args.contains("--now") {
        let pending = store.pending
        if pending.isEmpty { print(A.dim("No pending moves.")) } else { restartAndRun(pending) }
    } else {
        let all = store.all()
        if all.isEmpty { print(A.dim("No moves yet.")) }
        for m in all.suffix(30) {
            let mark: String
            switch m.status {
            case .pending: mark = A.clay("…")
            case .done: mark = A.green("✓")
            case .failed: mark = A.red("✗")
            case .conflict: mark = A.yellow("!")
            case .undone: mark = A.dim("↺")
            }
            print("\(mark) \(A.dim(m.id))  \(A.pad(A.trunc(m.title, 36), 37))\(A.dim(m.from.profileName + " → " + m.to.profileName))"
                  + (m.note.map { A.dim(" · " + $0) } ?? ""))
        }
    }

case nil, "watch":
    let monitor = Monitor(ownEngine: true)
    var latest: Snapshot?
    let lock = NSLock()
    monitor.onSnapshot = { s in lock.lock(); latest = s; lock.unlock() }
    if monitor.engine.owner {
        monitor.onEvent = { e in let (t, b) = describe(e); notify(t, b) }
    }
    monitor.start()

    var orig = termios()
    let interactive = isatty(STDIN_FILENO) == 1
    if interactive {
        tcgetattr(STDIN_FILENO, &orig)
        var raw = orig
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL) | O_NONBLOCK)
    }
    print("\u{1B}[?1049h\u{1B}[?25l", terminator: "")
    func restore() {
        print("\u{1B}[?25h\u{1B}[?1049l", terminator: "")
        if interactive { tcsetattr(STDIN_FILENO, TCSANOW, &orig) }
        monitor.stop()
    }
    signal(SIGINT) { _ in print("\u{1B}[?25h\u{1B}[?1049l", terminator: ""); exit(0) }

    var frames = 0
    loop: while true {
        var c: UInt8 = 0
        while read(STDIN_FILENO, &c, 1) == 1 {
            switch c {
            case UInt8(ascii: "q"): break loop
            case UInt8(ascii: "r"): monitor.refreshNow()
            case UInt8(ascii: "R"): RetryRequest.append(.all); monitor.refreshNow()
            default: break
            }
        }
        lock.lock(); let snap = latest; lock.unlock()
        var screen = "\u{1B}[H"
        if let snap {
            screen += render(snap, width: termWidth())
        } else {
            let spin = ["✻", "✺", "✹", "✸"][frames % 4]
            screen += A.clay(spin) + " Reading transcripts (the first run scans the last 7 days)…"
        }
        screen += "\n" + A.dim("q quit · r refresh · R retry due chats now")
        print(screen.replacingOccurrences(of: "\n", with: "\u{1B}[K\n") + "\u{1B}[J", terminator: "")
        fflush(stdout)
        frames += 1
        usleep(500_000)
    }
    restore()

default:
    usage()
}
