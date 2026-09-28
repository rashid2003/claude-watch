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

    /// Marks waiting items of a profile (or all) as due immediately.
    public func retryNow(profileId: String?) {
        for i in items.indices where items[i].status == .waiting
            && (profileId == nil || items[i].profileId == profileId) {
            items[i].resetsAt = Date.distantPast
        }
        saveState()
    }

    public func dismiss(itemId: String) {
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
        let request = Paths.support.appendingPathComponent("retry-request")
        if let who = try? String(contentsOf: request, encoding: .utf8) {
            try? FileManager.default.removeItem(at: request)
            let id = who.trimmingCharacters(in: .whitespacesAndNewlines)
            retryNow(profileId: id == "*" || id.isEmpty ? nil : id)
            lastExecution = .distantPast
        }
        let byId = Dictionary(statuses.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let acct = Dictionary(accounts.flatMap { a in a.memberProfileIds.map { ($0, a) } }, uniquingKeysWith: { a, _ in a })

        // 1. Enqueue newly failed sessions / detect re-limits.
        for s in statuses where s.activity == .failed {
            guard let hit = s.tail.lastRateLimit else { continue }
            if let idx = items.firstIndex(where: { $0.sessionId == s.id && [.waiting, .running, .verifying].contains($0.status) }) {
                if items[idx].status == .verifying, hit.at > (items[idx].lastAttemptAt ?? .distantPast) {
                    log(items[idx], outcome: "relimited", detail: hit.text, now: now)
                    if hit.resetsAt == nil && items[idx].attempts >= config.maxAttempts {
                        items[idx].status = .failed
                        items[idx].note = "Still limited: \(hit.text)"
                        onEvent?(items[idx], "Gave up on “\(items[idx].title)”: \(hit.text)")
                        changed = true
                        continue
                    }
                    items[idx].status = .waiting
                    items[idx].failedAt = hit.at
                    items[idx].resetsAt = hit.resetsAt
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
            if items[i].profileId != s.info.profileId { items[i].profileId = s.info.profileId; changed = true }
            let it = items[i]
            let tail = s.tail
            switch it.status {
            case .waiting:
                if tail.last != .rateLimited, let at = tail.lastAt, at > it.failedAt {
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
                    if it.attempts >= config.maxAttempts {
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
        if now.timeIntervalSince(lastExecution) > 8,
           let i = items.indices.first(where: { idx in
               let it = items[idx]
               guard it.status == .waiting else { return false }
               let due = (it.resetsAt ?? now).addingTimeInterval(config.retryDelaySeconds)
               guard now >= due else { return false }
               if let a = acct[it.profileId], a.state == .limited, (a.limitedUntil ?? .distantFuture) > now,
                  it.resetsAt != .distantPast { return false }
               return true
           }) {
            let mode = acct[items[i].profileId]?.retryMode ?? config.retryMode(for: items[i].profileId)
            let profile = profiles.first { $0.id == items[i].profileId }
            lastExecution = now
            changed = true
            if mode == .off || profile == nil {
                let key = items[i].profileId + "@" + String(Int((items[i].resetsAt ?? now).timeIntervalSince1970 / 600))
                items[i].status = .resolved
                items[i].note = "Ready to resume manually"
                if !readyNotified.contains(key) {
                    readyNotified.insert(key)
                    let n = items.filter { $0.profileId == items[i].profileId && $0.status == .waiting }.count + 1
                    onEvent?(items[i], "\(profile?.name ?? items[i].profileId) is free: \(n) chat\(n == 1 ? "" : "s") to resume")
                }
            } else if let profile, let session = byId[items[i].sessionId]?.info {
                items[i].attempts += 1
                items[i].lastAttemptAt = now
                items[i].lastMode = mode
                items[i].status = .verifying
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
                    items[i].attempts -= 1
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
                    if items[i].attempts >= config.maxAttempts || err.permanent {
                        items[i].status = .failed
                        onEvent?(items[i], "Retry failed: \(err.message)")
                    } else {
                        items[i].status = .waiting
                        items[i].resetsAt = now.addingTimeInterval(120 - config.retryDelaySeconds)
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

public struct RetryError: Error, Sendable {
    public var message: String
    public var permanent: Bool = false
    /// Waiting on a permission: doesn't count as an attempt.
    public var blocked: Bool = false
}
