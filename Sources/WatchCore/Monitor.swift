import Foundation

public enum WatchEvent: Sendable {
    case accountFree(Profile)
    case limitReset(Profile)
    case capSoon(Profile, LimitKind, Date)
    case limited(Profile, LimitKind?, Date?)
    case retry(RetryItem, String)   // item, human-readable message
    case moved(PendingMove)
}

/// Weighted-token time series for one account, with O(log n) range sums.
struct AccountTokens {
    private var keys: [Int] = []
    private var prefix: [Double] = [0]

    init(_ buckets: [TokenBuckets]) {
        var merged: [Int: Double] = [:]
        for b in buckets { for (k, v) in b.b { merged[k, default: 0] += v.weighted } }
        keys = merged.keys.sorted()
        prefix.reserveCapacity(keys.count + 1)
        for k in keys { prefix.append(prefix.last! + merged[k]!) }
    }

    private func lowerBound(_ k: Int) -> Int {
        var lo = 0, hi = keys.count
        while lo < hi { let m = (lo + hi) / 2; if keys[m] < k { lo = m + 1 } else { hi = m } }
        return lo
    }

    func sum(_ from: Date, _ to: Date) -> Double {
        guard to > from else { return 0 }
        let a = lowerBound(Int(from.timeIntervalSince1970 / TokenBuckets.width))
        let b = lowerBound(Int(to.timeIntervalSince1970 / TokenBuckets.width) + 1)
        return prefix[b] - prefix[a]
    }
}

public final class Monitor {
    /// Read from any thread (the bridge checks it per connection); written on the monitor queue.
    public private(set) var config: Config {
        get { configLock.withLock { _config } }
        set { configLock.withLock { _config = newValue } }
    }
    private var _config: Config
    private let configLock = NSLock()
    public private(set) var snapshot: Snapshot?
    public var onSnapshot: ((Snapshot) -> Void)?
    public var onEvent: ((WatchEvent) -> Void)?
    public let engine: RetryEngine

    private let queue = DispatchQueue(label: "claude-watch.monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var profiles: [Profile] = []
    private var profilesAt: Date = .distantPast
    private var configMtime: Date?
    private let sessionIndex = SessionIndex()
    private let attribution = Attribution()
    private let scanner = TranscriptScanner()
    private var usageCache: [String: (mtime: Date, samples: [UsageSample])] = [:]
    private var lastStates: [String: AccountState] = [:]
    private var pendingFree: [String: Date] = [:]
    private var capWarned: [String: Date] = [:]   // "profile/kind" -> window reset it was warned for
    private var firstPoll = true
    public let moves = MoveStore()
    private var locations: [ChatLocation] = []
    /// Desktop chats whose CLI process is running: session id -> pid (updated every poll).
    public private(set) var liveRunners: [String: Int32] = [:]

    public init(ownEngine: Bool = true) {
        _config = Config.load()
        engine = RetryEngine(owner: ownEngine && EngineLock.acquire())
        engine.onEvent = { [weak self] item, msg in self?.onEvent?(.retry(item, msg)) }
    }

    public func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: Self.interval(config.pollSeconds), leeway: .seconds(2))
        t.setEventHandler { [weak self] in autoreleasepool { self?.poll() } }
        timer = t
        timerInterval = Self.interval(config.pollSeconds)
        t.resume()
    }

    private var timerInterval: Double = 0
    private static func interval(_ s: Double) -> Double { max(3, s.isFinite ? s : 15) }

    /// Follows a changed `pollSeconds` (monitor queue only).
    private func rescheduleIfNeeded() {
        let want = Self.interval(config.pollSeconds)
        guard let timer, want != timerInterval else { return }
        timerInterval = want
        timer.schedule(deadline: .now() + want, repeating: want, leeway: .seconds(2))
    }

    public enum ConfigError: Error, LocalizedError {
        case unreadable
        public var errorDescription: String? {
            "config.json couldn't be read, so it wasn't overwritten. Fix or delete it, then try again."
        }
    }

    /// Edits config.json: re-reads it (so edits made elsewhere survive), applies `change`, saves
    /// atomically and applies the result right away. `done` gets the saved config or the error,
    /// on the monitor queue.
    public func updateConfig(_ change: @escaping (inout Config) -> Void,
                             done: ((Result<Config, Error>) -> Void)? = nil) {
        queue.async { [self] in
            var cfg: Config
            if FileManager.default.fileExists(atPath: Paths.config.path) {
                guard let disk = Config.load(from: Paths.config) else { done?(.failure(ConfigError.unreadable)); return }
                cfg = disk
            } else {
                cfg = config
            }
            change(&cfg)
            do {
                try cfg.save()
            } catch {
                done?(.failure(error)); return
            }
            config = cfg
            configMtime = Self.mtime(Paths.config)
            profilesAt = .distantPast
            rescheduleIfNeeded()
            done?(.success(cfg))
            poll()
        }
    }

    public func refreshNow() { queue.async { [weak self] in autoreleasepool { self?.poll() } } }

    public func perform(_ block: @escaping (Monitor) -> Void) { queue.async { [weak self] in if let self { block(self) } } }

    /// Runs `block` on the monitor queue and waits. Never call it from `perform` or the monitor queue.
    public func sync<T>(_ block: (Monitor) -> T) -> T { queue.sync { block(self) } }

    /// The transcript of a chat (monitor queue only: use from `perform` / `sync`).
    public func transcriptURL(cliSessionId: String) -> URL? { scanner.transcriptURL(cliSessionId: cliSessionId) }

    public func stop() { timer?.cancel(); scanner.save(); engine.saveState() }

    /// Runs one poll synchronously (for `claude-watch status`).
    public func pollOnce() -> Snapshot { queue.sync { autoreleasepool { poll() }; scanner.save(); return snapshot! } }

    public func setRetryMode(_ mode: RetryMode, for profileId: String) {
        updateConfig { cfg in
            var pc = cfg.profiles[profileId] ?? ProfileConfig()
            pc.retryMode = mode
            cfg.profiles[profileId] = pc
        }
    }

    public func profile(id: String) -> Profile? { profiles.first { $0.id == id } }

    /// Queues a move; it runs once both windows are closed. Nil if the chat already has one pending.
    public func requestMove(sessionId: String, title: String, from: ChatLocation, to: ChatLocation) -> PendingMove? {
        let m = moves.add(sessionId: sessionId, title: title, from: from, to: to)
        refreshNow()
        return m
    }

    public func undoMove(_ id: String) -> PendingMove? {
        let m = moves.undo(moveId: id)
        refreshNow()
        return m
    }

    public func cancelMove(_ id: String) { moves.cancel(id: id); refreshNow() }

    /// Quits the windows of the confirmed moves (`only moveIds`), runs those moves, and reopens
    /// the windows that quit plus each destination. Other pending moves are left to `poll`.
    /// `waiting` lists confirmed moves still pending afterwards (a window didn't quit, or the
    /// chat's CLI process is still alive). Blocking; call it off the main thread and never from `perform`.
    public func restartAndRunMoves(only moveIds: Set<String>)
        -> (stuck: [Profile], finished: [PendingMove], waiting: [PendingMove]) {
        let (pending, profs) = queue.sync { (moves.pending.filter { moveIds.contains($0.id) }, profiles) }
        guard !pending.isEmpty else { return ([], [], []) }
        let ids = Set(pending.flatMap { [$0.from.profileId, $0.to.profileId] })
        let (quit, stuck) = WindowControl.quit(profs.filter { ids.contains($0.id) })
        let (finished, waiting) = queue.sync {
            (runDueMoves(instances: ClaudeProcesses.list(), runners: Runners.list(), now: Date(), only: moveIds),
             moves.pending.filter { moveIds.contains($0.id) })
        }
        WindowControl.relaunch(profs.filter { p in quit.contains(p) || pending.contains { $0.to.profileId == p.id } })
        refreshNow()
        return (stuck, finished, waiting)
    }

    private func runDueMoves(instances: [ClaudeProcesses.Instance], runners: [Runner], now: Date,
                             only: Set<String>? = nil) -> [PendingMove] {
        guard !moves.pending.isEmpty else { return [] }
        let running = Set(profiles.filter { ClaudeProcesses.pid(for: $0, in: instances) != nil }.map(\.id))
        let finished = moves.runDue(profiles: profiles, running: running,
                                    liveSessions: Set(runners.map(\.sessionId)), only: only, now: now)
        for m in finished {
            if m.status == .done { attribution.record(m.sessionId, profileId: m.to.profileId) }
            onEvent?(.moved(m))
        }
        return finished
    }

    private static func mtime(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func samples(for p: Profile) -> [UsageSample] {
        let url = p.dataDir.appendingPathComponent("plan-usage-history.json")
        let m = Self.mtime(url) ?? .distantPast
        if let c = usageCache[p.id], c.mtime == m { return c.samples }
        let s = UsageHistoryReader.read(profile: p)
        usageCache[p.id] = (m, s)
        return s
    }

    private func poll() {
        let now = Date()
        if let m = Self.mtime(Paths.config), m != configMtime {
            configMtime = m
            config = Config.load()
            profilesAt = .distantPast
            rescheduleIfNeeded()
        }
        if now.timeIntervalSince(profilesAt) > 300 {
            profiles = ProfileDiscovery.discover(config: config)
            profilesAt = now
        }
        let instances = ClaudeProcesses.list()
        let runners = Runners.list()
        if engine.owner { _ = runDueMoves(instances: instances, runners: runners, now: now) }
        locations = SessionMover.locations(profiles: profiles, config: config)
        let std: (String) -> String = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path }
        let profileByDir = Dictionary(profiles.map { (std($0.dataDir.path), $0) }, uniquingKeysWith: { a, _ in a })
        var profileAccount: [String: String] = [:]
        var live = Set<String>()
        for r in runners {
            guard let p = profileByDir[std(r.dataDir)] else { continue }
            attribution.record(r.sessionId, profileId: p.id)
            live.insert(r.sessionId)
            if let a = r.identity { profileAccount[p.id] = a }
        }
        liveRunners = Dictionary(runners.map { ($0.sessionId, $0.pid) }, uniquingKeysWith: { a, _ in a })
        var prompts: [PendingPrompt] = []
        var procs: [ProcessTree.Proc]?

        // Chats are mirrored across profiles; pick the profile that actually runs each one.
        var candidates: [String: [SessionInfo]] = [:]
        for p in profiles {
            let copies = sessionIndex.sessions(for: p)
            if profileAccount[p.id] == nil { profileAccount[p.id] = copies.first?.accountUuid }
            for c in copies { candidates[c.id, default: []].append(c) }
        }
        scanner.scan(sessions: candidates.values.map { $0[0] }, now: now)
        let dirOf = Dictionary(profiles.map { ($0.id, std($0.dataDir.path) + "/") }, uniquingKeysWith: { a, _ in a })
        var all: [SessionInfo] = []
        var undecided: [[SessionInfo]] = []
        var resetOwner: [Date: String] = [:]   // limit reset time -> profile seen hitting it
        for (id, copies) in candidates {
            let remembered = attribution.profile(for: id)
            let known = copies.first { $0.profileId == remembered && (remembered != "default" || live.contains(id)) }
                ?? copies.first { c in dirOf[c.profileId].map { Self.realPath(c.cwd).hasPrefix($0) } ?? false }
            guard var chosen = known else { undecided.append(copies); continue }
            if let r = scanner.tail(forCli: chosen.cliSessionId).lastRateLimit?.resetsAt { resetOwner[r] = chosen.profileId }
            chosen.accountUuid = profileAccount[chosen.profileId] ?? chosen.accountUuid
            all.append(chosen)
        }
        for copies in undecided {
            // A chat that hit the same limit reset as a known chat ran on that account.
            let reset = scanner.tail(forCli: copies[0].cliSessionId).lastRateLimit?.resetsAt
            var chosen = reset.flatMap { r in resetOwner[r].flatMap { pid in copies.first { $0.profileId == pid } } }
                ?? copies.max { a, b in
                    // The default profile is only a fallback window; prefer the named launchers.
                    (a.profileId == "default" ? 0 : 1, a.recordModifiedAt) < (b.profileId == "default" ? 0 : 1, b.recordModifiedAt)
                }!
            chosen.accountUuid = profileAccount[chosen.profileId] ?? chosen.accountUuid
            all.append(chosen)
        }
        all.sort { $0.lastActivityAt > $1.lastActivityAt }
        attribution.save()

        var byAccount: [String: [SessionInfo]] = [:]
        for s in all { byAccount[s.accountUuid, default: []].append(s) }

        // Profiles signed into the same account are shown as one account.
        var groups: [(key: String, members: [Profile])] = []
        for p in profiles {
            let key = profileAccount[p.id] ?? "profile:" + p.id
            if let i = groups.firstIndex(where: { $0.key == key }) { groups[i].members.append(p) }
            else { groups.append((key, [p])) }
        }

        let moveList = moves.all()
        let arrivals = Self.arrivals(moveList)
        var accounts: [AccountStatus] = []
        var allStatuses: [SessionStatus] = []
        for g in groups {
            let p = g.members.first { !$0.isDefault } ?? g.members[0]
            let memberIds = Set(g.members.map(\.id))
            let accountUuid = g.key.hasPrefix("profile:") ? nil : g.key
            let accountSessions = accountUuid.flatMap { byAccount[$0] } ?? []
            let acct = AccountTokens(accountSessions.map { scanner.buckets(for: $0.id) })

            // A limit error only counts while nothing on the account has succeeded since.
            let tails = accountSessions.map { scanner.tail(for: $0) }
            let lastSuccess = tails.compactMap(\.lastSuccessAt).max() ?? .distantPast
            let allHits = zip(accountSessions, tails)
                .compactMap { s, t in Self.accountHit(t.lastRateLimit, sessionId: s.id, members: memberIds, arrivals: arrivals) }
                .filter { now.timeIntervalSince($0.at) < 8 * 86400 }
            let hits = allHits.filter { $0.at > lastSuccess }
            // Use whichever member window sampled usage most recently.
            let org = accountUuid?.split(separator: "/").last.map(String.init)
            let usage = g.members.map { m in samples(for: m).filter { org == nil || $0.org == org } }
                .max { ($0.last?.t ?? .distantPast) < ($1.last?.t ?? .distantPast) } ?? []
            let five = Forecaster.forecast(samples: usage, window: .fiveHour, rateLimits: allHits,
                                           tokens: acct.sum, now: now)
            let week = Forecaster.forecast(samples: usage, window: .weekly, rateLimits: allHits,
                                           tokens: acct.sum, now: now)

            var statuses: [SessionStatus] = []
            for s in accountSessions where !s.isArchived && memberIds.contains(s.profileId) {
                let tail = scanner.tail(for: s)
                var activity = Self.activity(session: s, tail: tail,
                                             transcriptMtime: s.cliSessionId.flatMap(scanner.transcriptURL).flatMap(Self.mtime),
                                             now: now)
                if activity == .idle, live.contains(s.id), let at = tail.lastAt, now.timeIntervalSince(at) < 1800,
                   tail.last != .assistantDone { activity = .working }
                // A running tool call with no result, a quiet transcript and no process for it: waiting on you.
                if let pid = liveRunners[s.id], tail.last == .assistantTool, activity != .failed,
                   let url = s.cliSessionId.flatMap(scanner.transcriptURL), let mtime = Self.mtime(url),
                   now.timeIntervalSince(mtime) >= 1, let open = PromptDetector.openToolUse(url: url) {
                    if procs == nil { procs = ProcessTree.all() }
                    let kids = ProcessTree.childStarts(of: [pid], in: procs!)[pid] ?? []
                    if PromptDetector.isWaiting(open, transcriptMtime: mtime, childStarts: kids, now: now) {
                        prompts.append(PromptDetector.prompt(for: s, tool: open))
                        activity = .waiting
                    }
                }
                let recent = now.timeIntervalSince(s.lastActivityAt) < 24 * 3600
                guard recent || activity != .idle else { continue }
                let b = scanner.buckets(for: s.id)
                statuses.append(SessionStatus(
                    info: s, activity: activity, tail: tail,
                    tasks: s.cliSessionId.map(TaskReader.tasks) ?? [],
                    tokens5h: b.sum(from: now.addingTimeInterval(-5 * 3600)).weighted,
                    tokens7d: b.sum(from: now.addingTimeInterval(-7 * 86400)).weighted))
            }
            statuses.sort { a, b in
                let rank: (SessionStatus.Activity) -> Int = { [.working: 0, .waiting: 1, .failed: 2, .idle: 3][$0]! }
                return rank(a.activity) != rank(b.activity) ? rank(a.activity) < rank(b.activity)
                                                              : a.info.lastActivityAt > b.info.lastActivityAt
            }
            allStatuses += statuses

            let pid = ClaudeProcesses.pid(for: p, in: instances)
                ?? g.members.lazy.compactMap { ClaudeProcesses.pid(for: $0, in: instances) }.first
            let activeHit = hits.filter { ($0.resetsAt ?? .distantPast) > now }.max { ($0.resetsAt ?? now) < ($1.resetsAt ?? now) }
            var limitedUntil = activeHit?.resetsAt
            var kind = activeHit?.kind
            let fresh: (LimitForecast) -> Bool = { f in (f.sampleAt.map { now.timeIntervalSince($0) < 1800 } ?? false) }
            // At 100% the account stays limited until the window's reset, however old the sample.
            let capped: (LimitForecast) -> Bool = { f in
                (f.percent ?? 0) >= 100 && (f.resetsAt.map { $0 > now } ?? fresh(f))
            }
            if limitedUntil == nil, capped(week) {
                limitedUntil = week.resetsAt; kind = .weekly
            } else if limitedUntil == nil, capped(five) {
                limitedUntil = five.resetsAt; kind = .fiveHour
            }
            let isLimited = activeHit != nil || kind != nil
            let working = statuses.contains { $0.activity == .working }
            let state: AccountState = isLimited ? .limited : working ? .working : (pid != nil ? .free : .offline)

            accounts.append(AccountStatus(
                profile: p, memberProfileIds: g.members.map(\.id),
                alsoOpenIn: g.members.filter { $0.id != p.id }.map(\.name),
                accountUuid: accountUuid, running: pid != nil, pid: pid, state: state,
                limitedUntil: limitedUntil, limitKind: isLimited ? kind : nil,
                fiveHour: five, weekly: week,
                tokens5h: acct.sum(now.addingTimeInterval(-5 * 3600), now),
                tokens7d: acct.sum(now.addingTimeInterval(-7 * 86400), now),
                tokensPerHourNow: acct.sum(now.addingTimeInterval(-1800), now) * 2,
                sessions: Array(statuses.prefix(10)),
                retryMode: config.retryMode(for: p.id)))
        }

        engine.update(statuses: allStatuses, accounts: accounts, profiles: profiles,
                      config: config, scanner: scanner, now: now)
        emitTransitions(accounts, now: now)
        firstPoll = false

        let snap = Snapshot(at: now, accounts: accounts, queue: engine.items,
                            engineOwner: engine.owner, scanning: false,
                            moves: moveList, locations: locations, profiles: profiles, prompts: prompts)
        snapshot = snap
        onSnapshot?(snap)
    }

    /// When each chat last landed in another account: the latest finished move per chat whose
    /// source and destination are different accounts (or orgs). An undo only reverses a move,
    /// so it isn't an arrival: the chat's hits from before the undone move stay where they were.
    static func arrivals(_ moves: [PendingMove]) -> [String: (profileId: String, at: Date)] {
        var out: [String: (profileId: String, at: Date)] = [:]
        for m in moves where m.status == .done && m.undoOf == nil {
            guard let at = m.finishedAt,
                  m.from.accountUuid != m.to.accountUuid || m.from.orgUuid != m.to.orgUuid else { continue }
            if let prev = out[m.sessionId], prev.at >= at { continue }
            out[m.sessionId] = (m.to.profileId, at)
        }
        return out
    }

    /// A chat's last limit hit as it counts for the account made of `members`: a hit from before
    /// the chat was moved into this account belongs to the old account and is dropped.
    static func accountHit(_ hit: RateLimitHit?, sessionId: String, members: Set<String>,
                           arrivals: [String: (profileId: String, at: Date)]) -> RateLimitHit? {
        guard let hit else { return nil }
        if let a = arrivals[sessionId], members.contains(a.profileId), hit.at < a.at { return nil }
        return hit
    }

    /// Resolves compatibility symlinks (e.g. ~/Claude-Profiles/account-1 -> claude-3-…).
    static func realPath(_ path: String) -> String {
        var url = URL(fileURLWithPath: path)
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 {
            tail.insert(url.lastPathComponent, at: 0)
            url.deleteLastPathComponent()
        }
        return tail.reduce(url.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.path
    }

    static func activity(session s: SessionInfo, tail: TranscriptTail, transcriptMtime: Date?, now: Date) -> SessionStatus.Activity {
        if tail.last == .rateLimited { return .failed }
        if s.hasPendingPermission { return .waiting }
        if let m = transcriptMtime, now.timeIntervalSince(m) < 30 { return .working }
        switch tail.last {
        case .userPrompt, .toolResult, .assistantTool:
            if let at = tail.lastAt, now.timeIntervalSince(at) < 600 { return .working }
        default: break
        }
        return .idle
    }

    private func emitTransitions(_ accounts: [AccountStatus], now: Date) {
        for a in accounts {
            let prev = lastStates[a.id]
            lastStates[a.id] = a.state
            if a.state != .free { pendingFree[a.id] = nil }
            if !firstPoll, let prev, prev != a.state {
                switch (prev, a.state) {
                case (.limited, _): onEvent?(.limitReset(a.profile))
                case (_, .limited): onEvent?(.limited(a.profile, a.limitKind, a.limitedUntil))
                case (.working, .free): pendingFree[a.id] = now
                default: break
                }
            }
            // Only announce "free" once it has stayed idle for a minute (tool calls flap).
            if let since = pendingFree[a.id], now.timeIntervalSince(since) >= 60 {
                pendingFree[a.id] = nil
                onEvent?(.accountFree(a.profile))
            }
            checkCapSoon(a, now: now)
        }
    }

    private func checkCapSoon(_ a: AccountStatus, now: Date) {
        guard a.state != .limited else { return }
        for (kind, f) in [(LimitKind.fiveHour, a.fiveHour), (.weekly, a.weekly)] {
            guard let hits = f.hitsAt, !f.resetsFirst,
                  hits.timeIntervalSince(now) < config.warnBeforeCapMinutes * 60 else { continue }
            let key = a.id + "/" + kind.rawValue
            let windowKey = f.resetsAt ?? hits
            if let w = capWarned[key], abs(w.timeIntervalSince(windowKey)) < 1800 { continue }
            capWarned[key] = windowKey
            onEvent?(.capSoon(a.profile, kind, hits))
        }
    }
}
