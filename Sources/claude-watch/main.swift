import Foundation
import WatchCore

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
        out.append("")
    }

    let active = snap.queue.filter { [.waiting, .running, .verifying].contains($0.status) }
    let recent = snap.queue.filter { ![.waiting, .running, .verifying].contains($0.status) }.suffix(3)
    if !active.isEmpty || !recent.isEmpty {
        out.append(A.bold("Retry queue"))
        for it in active {
            let name = snap.accounts.first { $0.id == it.profileId }?.profile.name ?? it.profileId
            var when = ""
            if it.status == .waiting, let r = it.resetsAt, r > .distantPast { when = r > now ? "in " + Fmt.duration(r.timeIntervalSince(now)) : "due" }
            else if it.status == .verifying { when = "checking reply…" }
            out.append("  " + A.clay("⟳") + " " + A.pad(A.trunc(name, 16), 17) + A.trunc(it.title, max(10, w - 44))
                       + "  " + A.dim(when) + (it.note.map { A.dim(" · " + $0) } ?? ""))
        }
        for it in recent {
            let mark = it.status == .done ? A.green("✓") : it.status == .failed ? A.red("✗") : A.dim("–")
            out.append("  " + mark + " " + A.dim(A.trunc(it.title, max(10, w - 30)) + (it.note.map { " · " + $0 } ?? "")))
        }
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
      claude-watch retry [profile]     retry waiting chats now (all or one profile)
      claude-watch probe [profile]     dry-run the UI retry path (opens a chat, types nothing)
      claude-watch mode <profile> <ui|cli|off>
      claude-watch set-token <profile> store a `claude setup-token` token for CLI retries
      claude-watch profiles            list discovered profiles
    """)
    exit(0)
}

func requestRetry(_ profile: String?) {
    let url = Paths.support.appendingPathComponent("retry-request")
    try? (profile ?? "*").write(to: url, atomically: true, encoding: .utf8)
}

func notify(_ title: String, _ body: String) {
    let esc: (String) -> String = { $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""]
    try? p.run()
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
                  + A.dim(it.resetsAt.map { " · resets " + Fmt.time($0) } ?? "") + A.dim(it.note.map { " · " + $0 } ?? ""))
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
    requestRetry(args.dropFirst().first)
    print("Requested. The retry engine will pick it up on its next poll.")

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
            case UInt8(ascii: "R"): requestRetry(nil); monitor.refreshNow()
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
