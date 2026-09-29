import Foundation

/// Ensures only one process (menu-bar app or TUI) executes retries.
public enum EngineLock {
    private static var fd: Int32 = -1

    public static func acquire() -> Bool {
        if fd >= 0 { return true }
        let f = open(Paths.engineLock.path, O_CREAT | O_RDWR, 0o644)
        guard f >= 0 else { return false }
        if flock(f, LOCK_EX | LOCK_NB) == 0 { fd = f; return true }
        close(f)
        return false
    }
}

struct EngineState: Codable {
    var items: [RetryItem] = []
}

public final class RetryEngine {
    public private(set) var owner: Bool
    public private(set) var items: [RetryItem] = []
    public var onEvent: ((RetryItem, String) -> Void)?
    private var lastExecution: Date = .distantPast
    private var stateMtime: Date?
    private var readyNotified = Set<String>()

    init(owner: Bool) {
        self.owner = owner
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Paths.state),
              let st = try? JSONCoder.decoder.decode(EngineState.self, from: data) else { return }
        items = st.items.map { var it = $0; it.profileId = ProfileDiscovery.canonicalId(it.profileId); return it }
    }

    public func saveState() {
        guard owner, let data = try? JSONCoder.pretty.encode(EngineState(items: items)) else { return }
        try? data.write(to: Paths.state, options: .atomic)
    }

    /// Runs a user action here if this process owns the engine; otherwise forwards it to the owner
    /// through the retry-request file (changing the local read-only copy would be lost).
    public func request(_ r: RetryRequest) {
        if owner { apply(r) } else { RetryRequest.append(r) }
    }

    func apply(_ r: RetryRequest) {
        switch r {
        case .all: retryNow(profileId: nil)
        case .profile(let id): retryNow(profileId: id)
        case .item(let key): if !retryNow(itemId: key) { retryNow(sessionId: key) }
        case .dismiss(let id): dismiss(itemId: id)
        }
    }

    /// Marks waiting items of a profile (or all) as due immediately, even while the account is limited.
    func retryNow(profileId: String?) {
        for i in items.indices where items[i].status == .waiting
            && (profileId == nil || items[i].profileId == profileId) {
            _ = Self.forceDue(&items[i])
        }
        lastExecution = .distantPast
        saveState()
    }

    /// Makes one item due immediately, even while its account is limited. A failed item
    /// (attempts used up) goes back to waiting with its attempts reset. Returns false if the
    /// item isn't waiting or failed.
    @discardableResult
    func retryNow(itemId: String) -> Bool {
        guard let i = items.firstIndex(where: { $0.id == itemId }), Self.forceDue(&items[i]) else { return false }
        lastExecution = .distantPast
        saveState()
        return true
    }

    /// Same as `retryNow(itemId:)` for the newest waiting or failed item of a chat.
    @discardableResult
    func retryNow(sessionId: String) -> Bool {
        guard let it = items.last(where: { $0.sessionId == sessionId && [.waiting, .failed].contains($0.status) })
        else { return false }
        return retryNow(itemId: it.id)
    }

    /// Marker for "the user asked to retry this now": due at once, ignores the account's limit.
    static let forcedAt = Date.distantPast

    /// Makes an item due at once. Waiting items keep their attempts; failed ones start over.
    static func forceDue(_ it: inout RetryItem) -> Bool {
        switch it.status {
        case .waiting:
            it.resetsAt = forcedAt
        case .failed:
            it.status = .waiting
            it.attempts = 0
            it.resetsAt = forcedAt
            it.note = "Retrying now"
        default:
            return false
        }
        return true
    }

    /// Whether a waiting item should be sent now. `limitedUntil` is the account's reset time when it
    /// is limited (nil otherwise). Forced items go out even while the account is still limited; if
    /// they hit the limit again the relimited path puts them back to waiting.
    /// A chat moved to another profile: a waiting item follows it and drops the old account's
    /// reset, waiting for the new account's instead (or just the retry delay if it's free).
    /// A forced "Retry now" stays forced.
    static func rehomed(_ it: RetryItem, to profileId: String, limitedUntil: Date?) -> RetryItem {
        var it = it
        it.profileId = profileId
        if it.status == .waiting, it.resetsAt != forcedAt { it.resetsAt = limitedUntil ?? it.failedAt }
        return it
    }

    static func isDue(_ it: RetryItem, limitedUntil: Date?, retryDelay: TimeInterval, now: Date) -> Bool {
        guard it.status == .waiting else { return false }
        if it.resetsAt == forcedAt { return true }
        guard now >= (it.resetsAt ?? now).addingTimeInterval(retryDelay) else { return false }
        if let until = limitedUntil, until > now { return false }
        return true
    }

    /// How a due item is sent: the account's mode, except that "Retry now" on an account set to
    /// `off` sends once via UI (the user asked for it). Nil = leave it for the user to resume.
    static func sendMode(for it: RetryItem, configured: RetryMode) -> RetryMode? {
        if configured != .off { return configured }
        return it.resetsAt == forcedAt ? .ui : nil
    }

    /// Marks an item as sent. A user-requested send doesn't use up one of the automatic attempts.
    static func beginSend(_ it: inout RetryItem, mode: RetryMode, now: Date) {
        let manual = it.resetsAt == forcedAt
        if !manual { it.attempts += 1 }
        it.lastSendManual = manual
        it.lastAttemptAt = now
        it.lastMode = mode
        it.status = .verifying
    }

    /// Whether the outcome of the last send should make the item give up.
    static func outOfAttempts(_ it: RetryItem, max: Int) -> Bool {
        it.lastSendManual != true && it.attempts >= max
    }

    /// The first due item whose chat still exists, plus the due items before it whose chat is gone
    /// (so one missing chat can't hold up the rest of the queue).
    static func pickDue(_ items: [RetryItem], isDue: (RetryItem) -> Bool,
                        hasChat: (RetryItem) -> Bool) -> (send: Int?, missing: [Int]) {
        var missing: [Int] = []
        for i in items.indices where isDue(items[i]) {
            if hasChat(items[i]) { return (i, missing) }
            missing.append(i)
        }
        return (nil, missing)
    }

    /// A waiting item's chat moved on without us. After we've sent once, a trailing user prompt may be
    /// our own message, so only a reply counts then.
    static func continuedManually(_ it: RetryItem, tail: TranscriptTail) -> Bool {
        guard tail.last != .rateLimited, let at = tail.lastAt, at > it.failedAt else { return false }
        if let sent = it.lastAttemptAt, tail.last == .userPrompt || at <= sent { return false }
        return true
    }

    func dismiss(itemId: String) {
        items.removeAll { $0.id == itemId }
        saveState()
    }

    func update(statuses: [SessionStatus], accounts: [AccountStatus], profiles: [Profile],
                config: Config, scanner: TranscriptScanner, now: Date) {
        guard owner else {
            // Read-only mirror of the owner's queue.
            let m = (try? FileManager.default.attributesOfItem(atPath: Paths.state.path))?[.modificationDate] as? Date
            if m != stateMtime { stateMtime = m; load() }
            return
        }
        var changed = false
        let requests = RetryRequest.take(from: Paths.retryRequest)
        for r in requests { apply(r) }
        if !requests.isEmpty { lastExecution = .distantPast }
        let byId = Dictionary(statuses.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let acct = Dictionary(accounts.flatMap { a in a.memberProfileIds.map { ($0, a) } }, uniquingKeysWith: { a, _ in a })

        // 1. Enqueue newly failed sessions / detect re-limits.
        for s in statuses where s.activity == .failed {
            guard let hit = s.tail.lastRateLimit else { continue }
            if let idx = items.firstIndex(where: { $0.sessionId == s.id && [.waiting, .running, .verifying].contains($0.status) }) {
                if items[idx].status == .verifying, hit.at > (items[idx].lastAttemptAt ?? .distantPast) {
                    log(items[idx], outcome: "relimited", detail: hit.text, now: now)
                    if hit.resetsAt == nil && Self.outOfAttempts(items[idx], max: config.maxAttempts) {
                        items[idx].status = .failed
                        items[idx].note = "Still limited: \(hit.text)"
                        onEvent?(items[idx], "Gave up on “\(items[idx].title)”: \(hit.text)")
                        changed = true
                        continue
                    }
                    items[idx].status = .waiting
                    items[idx].failedAt = hit.at
                    items[idx].resetsAt = hit.resetsAt ?? acct[items[idx].profileId]?.limitedUntil
                        ?? hit.at.addingTimeInterval(1800)
                    items[idx].note = "Hit the limit again"
                    changed = true
                }
                continue
            }
            if items.contains(where: { $0.sessionId == s.id && abs($0.failedAt.timeIntervalSince(hit.at)) < 1 }) { continue }
            guard now.timeIntervalSince(hit.at) < config.maxFailureAgeHours * 3600 else { continue }
            let a = acct[s.info.profileId]
            items.append(RetryItem(sessionId: s.id, cliSessionId: s.info.cliSessionId, profileId: s.info.profileId,
                                   title: s.info.title, cwd: s.info.cwd, failedAt: hit.at,
                                   resetsAt: hit.resetsAt ?? a?.limitedUntil ?? hit.at.addingTimeInterval(1800), status: .waiting,
                                   attempts: 0, lastAttemptAt: nil, lastMode: nil, note: nil))
            changed = true
        }

        // 2. Resolve / verify.
        for i in items.indices {
            guard let s = byId[items[i].sessionId] else { continue }
            if items[i].profileId != s.info.profileId {
                let a = acct[s.info.profileId]
                items[i] = Self.rehomed(items[i], to: s.info.profileId,
                                        limitedUntil: a?.state == .limited ? a?.limitedUntil : nil)
                changed = true
            }
            let it = items[i]
            let tail = s.tail
            switch it.status {
            case .waiting:
                if Self.continuedManually(it, tail: tail) {
                    items[i].status = .resolved
                    items[i].note = "Continued manually"
                    changed = true
                }
            case .verifying, .running:
                let since = it.lastAttemptAt ?? it.failedAt
                if let at = tail.lastAt, at > since, [.assistantDone, .assistantTool, .toolResult].contains(tail.last) {
                    items[i].status = .done
                    items[i].note = "Resumed"
                    log(items[i], outcome: "verified", detail: nil, now: now,
                        latency: at.timeIntervalSince(since))
                    onEvent?(items[i], "Resumed “\(it.title)”")
                    changed = true
                } else if now.timeIntervalSince(since) > config.verifyTimeoutSeconds, tail.last != .userPrompt || tail.lastAt.map({ $0 < since }) ?? true {
                    log(it, outcome: "no_response", detail: nil, now: now)
                    if Self.outOfAttempts(it, max: config.maxAttempts) {
                        items[i].status = .failed
                        items[i].note = "No response after \(it.attempts) attempts"
                        onEvent?(items[i], "Couldn't resume “\(it.title)”")
                    } else {
                        items[i].status = .waiting
                        items[i].resetsAt = now.addingTimeInterval(90 - config.retryDelaySeconds)
                        items[i].note = "No response, trying again"
                    }
                    changed = true
                }
            default: break
            }
        }

        // 3. Execute at most one due item per poll (UI automation must be serialised).
        if now.timeIntervalSince(lastExecution) > 8 {
            let pick = Self.pickDue(items, isDue: { it in
                let a = acct[it.profileId]
                return Self.isDue(it, limitedUntil: a?.state == .limited ? (a?.limitedUntil ?? .distantFuture) : nil,
                                  retryDelay: config.retryDelaySeconds, now: now)
            }, hasChat: { byId[$0.sessionId] != nil })
            for i in pick.missing {
                items[i].status = .failed
                items[i].note = "Chat not found"
                changed = true
            }
            if let i = pick.send, let session = byId[items[i].sessionId]?.info {
                let configured = acct[items[i].profileId]?.retryMode ?? config.retryMode(for: items[i].profileId)
                let profile = profiles.first { $0.id == items[i].profileId }
                lastExecution = now
                changed = true
                if let profile, let mode = Self.sendMode(for: items[i], configured: configured) {
                    Self.beginSend(&items[i], mode: mode, now: now)
                    let result: Result<String, RetryError>
                    switch mode {
                    case .ui: result = UIRetry.send(message: config.retryMessage, session: session, profile: profile)
                    case .cli: result = CLIRetry.send(message: config.retryMessage, session: session, profile: profile,
                                                      extraArgs: config.cliExtraArgs)
                    case .off: result = .success("")
                    }
                    switch result {
                    case .success(let detail):
                        items[i].note = "Sent via \(mode.rawValue.uppercased())"
                        log(items[i], outcome: "sent", detail: detail, now: now)
                    case .failure(let err) where err.blocked:
                        if items[i].lastSendManual != true { items[i].attempts -= 1 }
                        items[i].status = .waiting
                        items[i].note = err.message
                        items[i].resetsAt = now.addingTimeInterval(60 - config.retryDelaySeconds)
                        if !readyNotified.contains(err.message) {
                            readyNotified.insert(err.message)
                            onEvent?(items[i], err.message + ". Chats will resume once it's granted.")
                        }
                    case .failure(let err):
                        log(items[i], outcome: "send_failed", detail: err.message, now: now)
                        items[i].note = err.message
                        if Self.outOfAttempts(items[i], max: config.maxAttempts) || err.permanent {
                            items[i].status = .failed
                            onEvent?(items[i], "Retry failed: \(err.message)")
                        } else {
                            items[i].status = .waiting
                            items[i].resetsAt = now.addingTimeInterval(120 - config.retryDelaySeconds)
                        }
                    }
                } else if items[i].resetsAt == Self.forcedAt {
                    // "Retry now" but the profile is gone: don't report the account as free.
                    items[i].status = .failed
                    items[i].note = "Profile not found"
                } else {
                    let key = items[i].profileId + "@" + String(Int((items[i].resetsAt ?? now).timeIntervalSince1970 / 600))
                    items[i].status = .resolved
                    items[i].note = "Ready to resume manually"
                    if !readyNotified.contains(key) {
                        readyNotified.insert(key)
                        let n = items.filter { $0.profileId == items[i].profileId && $0.status == .waiting }.count + 1
                        onEvent?(items[i], "\(profile?.name ?? items[i].profileId) is free: \(n) chat\(n == 1 ? "" : "s") to resume")
                    }
                }
            }
        }

        // 4. Prune finished items after a day.
        let before = items.count
        items.removeAll { [.done, .resolved, .failed].contains($0.status)
            && now.timeIntervalSince($0.lastAttemptAt ?? $0.failedAt) > 86400 }
        if changed || items.count != before { saveState() }
    }

    private func log(_ it: RetryItem, outcome: String, detail: String?, now: Date, latency: Double? = nil) {
        let e = RetryLogEntry(at: now, sessionId: it.sessionId, profileId: it.profileId,
                              mode: it.lastMode ?? .off, outcome: outcome, detail: detail, latencySeconds: latency)
        guard var line = try? JSONCoder.encoder.encode(e) else { return }
        line.append(0x0A)
        if let h = try? FileHandle(forWritingTo: Paths.retryLog) {
            h.seekToEndOfFile(); h.write(line); try? h.close()
        } else {
            try? line.write(to: Paths.retryLog)
        }
    }

    public struct ModeStats: Sendable {
        public var mode: RetryMode
        public var sent = 0, sendFailed = 0, verified = 0, relimited = 0, noResponse = 0
        public var avgLatency: Double?
    }

    public static func stats() -> [ModeStats] {
        guard let data = try? String(contentsOf: Paths.retryLog, encoding: .utf8) else { return [] }
        var m: [RetryMode: ModeStats] = [:]
        var lat: [RetryMode: [Double]] = [:]
        for line in data.split(separator: "\n") {
            guard let e = try? JSONCoder.decoder.decode(RetryLogEntry.self, from: Data(line.utf8)) else { continue }
            var s = m[e.mode] ?? ModeStats(mode: e.mode)
            switch e.outcome {
            case "sent": s.sent += 1
            case "send_failed": s.sendFailed += 1
            case "verified": s.verified += 1; if let l = e.latencySeconds { lat[e.mode, default: []].append(l) }
            case "relimited": s.relimited += 1
            case "no_response": s.noResponse += 1
            default: break
            }
            m[e.mode] = s
        }
        for (k, v) in lat where !v.isEmpty { m[k]?.avgLatency = v.reduce(0, +) / Double(v.count) }
        return RetryMode.allCases.compactMap { m[$0] }
    }
}

/// A user action forwarded to the process that owns the retry engine. Stored one per line in
/// `Paths.retryRequest`: "*" = all, "item:<item or session id>", "dismiss:<item id>", else a profile id.
public enum RetryRequest: Equatable, Sendable {
    case all
    case profile(String)
    case item(String)
    case dismiss(String)

    public var line: String {
        switch self {
        case .all: "*"
        case .profile(let id): id
        case .item(let key): "item:" + key
        case .dismiss(let id): "dismiss:" + id
        }
    }

    /// Parses a request file. Also reads the old single-value files (no trailing newline).
    /// Empty lines are ignored, so a file caught mid-write never turns into "retry everything".
    static func parse(_ text: String) -> [RetryRequest] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { l in
                if l == "*" { return .all }
                if l.hasPrefix("item:") { return .item(String(l.dropFirst(5))) }
                if l.hasPrefix("dismiss:") { return .dismiss(String(l.dropFirst(8))) }
                return .profile(l)
            }
    }

    /// Appends one request line. Holds an exclusive lock while writing and re-checks that the path
    /// still names the open file, so a concurrent `take` never drops it.
    public static func append(_ r: RetryRequest, to url: URL = Paths.retryRequest) {
        let bytes = Array((r.line + "\n").utf8)
        for _ in 0..<10 {
            let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            guard fd >= 0 else { return }
            defer { close(fd) }
            flock(fd, LOCK_EX)
            var opened = stat(), named = stat()
            guard fstat(fd, &opened) == 0, stat(url.path, &named) == 0,
                  opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else { continue }   // claimed meanwhile
            _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
            return
        }
    }

    /// Claims the request file (atomic rename), waits for any writer still appending, reads every
    /// request and deletes it.
    static func take(from url: URL) -> [RetryRequest] {
        let claimed = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(getpid()).\(UUID().uuidString)")
        guard rename(url.path, claimed.path) == 0 else { return [] }
        defer { unlink(claimed.path) }
        let fd = open(claimed.path, O_RDONLY)
        guard fd >= 0 else { return [] }
        flock(fd, LOCK_EX)
        let data = FileHandle(fileDescriptor: fd, closeOnDealloc: true).readDataToEndOfFile()
        return parse(String(decoding: data, as: UTF8.self))
    }
}

public struct RetryError: Error, Sendable {
    public var message: String
    public var permanent: Bool = false
    /// Waiting on a permission: doesn't count as an attempt.
    public var blocked: Bool = false
}
