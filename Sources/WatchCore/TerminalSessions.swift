import Foundation

extension Profile {
    /// The pseudo profile terminal chats belong to (never a desktop window; not in `Snapshot.profiles`).
    public static var terminal: Profile { Profile(id: terminalId, name: "Terminal", dataDir: Paths.claudeHome) }
}

/// One `~/.claude/sessions/<pid>.json` entry: Claude Code's registry of running sessions.
public struct RegistryEntry: Equatable, Sendable {
    public var pid: Int32
    public var sessionId: String
    public var cwd: String
    public var name: String?
    public var status: String?          // "busy" / "idle"
    public var entrypoint: String?      // "claude-desktop", "cli", "sdk-cli", …
    public var kind: String?            // "interactive", …
    public var hostSessionId: String?   // the desktop chat (desktop runs only)
    public var startedAt: Date?
    public var updatedAt: Date?

    public init(pid: Int32, sessionId: String, cwd: String, name: String? = nil, status: String? = nil,
                entrypoint: String? = nil, kind: String? = nil, hostSessionId: String? = nil,
                startedAt: Date? = nil, updatedAt: Date? = nil) {
        self.pid = pid; self.sessionId = sessionId; self.cwd = cwd; self.name = name; self.status = status
        self.entrypoint = entrypoint; self.kind = kind; self.hostSessionId = hostSessionId
        self.startedAt = startedAt; self.updatedAt = updatedAt
    }

    /// Spawned by a desktop window for one of its chats.
    public var isDesktop: Bool { entrypoint == "claude-desktop" || !(hostSessionId ?? "").isEmpty }
    /// A session someone is typing into (headless `-p` runs register too, but nobody is at them).
    public var isInteractive: Bool { (kind == nil || kind == "interactive") && !(entrypoint ?? "").hasPrefix("sdk") }

    static func parse(_ d: [String: Any]) -> RegistryEntry? {
        guard let pid = (d["pid"] as? NSNumber)?.int32Value, pid > 0,
              let sid = d["sessionId"] as? String, !sid.isEmpty else { return nil }
        return RegistryEntry(pid: pid, sessionId: sid, cwd: d["cwd"] as? String ?? "",
                             name: (d["name"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                             status: d["status"] as? String, entrypoint: d["entrypoint"] as? String,
                             kind: d["kind"] as? String, hostSessionId: d["hostSessionId"] as? String,
                             startedAt: JSONFile.date(ms: d["startedAt"]),
                             updatedAt: JSONFile.date(ms: d["updatedAt"] ?? d["statusUpdatedAt"]))
    }
}

/// The account the `claude` CLI is signed into (`~/.claude.json` → `oauthAccount`).
public struct CLIAccount: Equatable, Sendable {
    public var accountUuid: String
    public var orgUuid: String?
    public var email: String?
    /// "account/org", the same key desktop chats are grouped by.
    public var identity: String { orgUuid.map { accountUuid + "/" + $0 } ?? accountUuid }

    public init(accountUuid: String, orgUuid: String?, email: String?) {
        self.accountUuid = accountUuid; self.orgUuid = orgUuid; self.email = email
    }

    public static func read(from url: URL = Paths.claudeGlobalConfig) -> CLIAccount? {
        guard let d = JSONFile.object(at: url), let oa = d["oauthAccount"] as? [String: Any],
              let a = oa["accountUuid"] as? String, !a.isEmpty else { return nil }
        let org = (oa["organizationUuid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return CLIAccount(accountUuid: a, orgUuid: org, email: oa["emailAddress"] as? String)
    }
}

/// What the head and tail of a transcript say about the chat (cached per file size).
struct TranscriptMeta: Equatable {
    var entrypoint: String?
    var cwd: String?
    var firstPrompt: String?
    var title: String?
    var hasUser = false
}

/// Finds Claude Code sessions that don't belong to a desktop chat: running ones from the session
/// registry, plus recent transcripts in `~/.claude/projects` written by the `claude` CLI.
public final class TerminalSessionIndex {
    public static let window: TimeInterval = 7 * 86400
    private let registryDir: URL
    private let projectsDir: URL
    private let isAlive: (RegistryEntry) -> Bool
    private var meta: [String: (size: UInt64, mtime: Date, meta: TranscriptMeta)] = [:]
    private var files: [String: (url: URL, mtime: Date)] = [:]   // session id -> newest transcript
    private var listedAt: Date = .distantPast

    /// `isAlive` defaults to checking the pid against the process table (and its start time,
    /// so a recycled pid doesn't count).
    public init(registryDir: URL = Paths.sessionRegistry, projectsDir: URL = Paths.projects,
                isAlive: ((RegistryEntry) -> Bool)? = nil) {
        self.registryDir = registryDir
        self.projectsDir = projectsDir
        self.isAlive = isAlive ?? Self.processAlive
    }

    /// Every parseable registry entry, live or not.
    public func registry() -> [RegistryEntry] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: registryDir.path)) ?? [])
            .filter { $0.hasSuffix(".json") }
            .compactMap { JSONFile.object(at: registryDir.appendingPathComponent($0)).flatMap(RegistryEntry.parse) }
    }

    /// Registry entries of running non-desktop sessions.
    public func liveEntries() -> [RegistryEntry] {
        registry().filter { !$0.isDesktop && isAlive($0) }
    }

    /// Terminal chats: transcripts active within `window` (or with a running process) whose id isn't
    /// any desktop chat's CLI session, written by the CLI rather than the desktop app or a script.
    /// `live` are the running non-desktop registry entries (see `liveEntries`).
    public func sessions(excluding desktopIds: Set<String>, live: [RegistryEntry], accountUuid: String,
                         now: Date = Date(), window: TimeInterval = TerminalSessionIndex.window) -> [SessionInfo] {
        let stale = now.timeIntervalSince(listedAt)
        if stale > 30 || (stale > 5 && live.contains { files[$0.sessionId] == nil }) {
            listFiles()
            listedAt = now
        }
        var liveById: [String: RegistryEntry] = [:]
        for e in live where !desktopIds.contains(e.sessionId) {
            if let old = liveById[e.sessionId], old.isInteractive { continue }
            liveById[e.sessionId] = e
        }
        var out: [SessionInfo] = []
        for (id, f) in files where !desktopIds.contains(id) {
            let entry = liveById[id]
            guard entry != nil || now.timeIntervalSince(f.mtime) < window else { continue }
            let m = transcriptMeta(f.url, mtime: f.mtime)
            guard m.hasUser || entry != nil else { continue }
            if let e = m.entrypoint {
                // Desktop chats (even ones whose record is gone) and scripted `claude -p` runs aren't terminal chats.
                if e == "claude-desktop" { continue }
                if e.hasPrefix("sdk"), entry?.isInteractive != true { continue }
            }
            out.append(Self.info(id: id, meta: m, mtime: f.mtime, entry: entry, accountUuid: accountUuid))
        }
        let paths = Set(files.values.map(\.url.path))
        meta = meta.filter { paths.contains($0.key) }
        return out.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    static func info(id: String, meta m: TranscriptMeta, mtime: Date, entry: RegistryEntry?, accountUuid: String) -> SessionInfo {
        let cwd = m.cwd ?? entry?.cwd ?? ""
        let title = entry?.name ?? m.title ?? m.firstPrompt.map { Self.clip($0, 80) }
            ?? ((cwd as NSString).lastPathComponent.isEmpty ? "Terminal chat" : (cwd as NSString).lastPathComponent)
        var info = SessionInfo(id: id, cliSessionId: id, priorCliSessionIds: [], profileId: Profile.terminalId,
                               accountUuid: accountUuid, title: title, cwd: cwd, model: nil, permissionMode: nil,
                               lastActivityAt: max(mtime, entry?.updatedAt ?? .distantPast), isArchived: false,
                               desktopError: nil, desktopErrorAt: nil, hasPendingPermission: false,
                               recordModifiedAt: mtime, folder: "")
        info.isTerminal = true
        info.openInTerminal = entry?.isInteractive == true ? true : nil
        return info
    }

    static func clip(_ s: String, _ n: Int) -> String {
        let one = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
        let t = one.trimmingCharacters(in: .whitespaces)
        return t.count > n ? String(t.prefix(n - 1)) + "…" : t
    }

    private func listFiles() {
        let fm = FileManager.default
        var out: [String: (url: URL, mtime: Date)] = [:]
        for dir in (try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil)) ?? [] {
            for entry in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where entry.hasSuffix(".jsonl") {
                let id = String(entry.dropLast(6))
                guard id.count == 36, UUID(uuidString: id) != nil else { continue }
                let url = dir.appendingPathComponent(entry)
                let mtime = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
                if let old = out[id], old.mtime >= mtime { continue }
                out[id] = (url, mtime)
            }
        }
        files = out
    }

    private func transcriptMeta(_ url: URL, mtime: Date) -> TranscriptMeta {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
        if let c = meta[url.path], c.size == size, c.mtime == mtime { return c.meta }
        let m = autoreleasepool { Self.readMeta(url, size: size) }
        meta[url.path] = (size, mtime, m)
        return m
    }

    /// Reads the first 64 KB (entrypoint, cwd, first prompt) and the last 256 KB (newest title).
    static func readMeta(_ url: URL, size: UInt64) -> TranscriptMeta {
        guard let h = try? FileHandle(forReadingFrom: url) else { return TranscriptMeta() }
        defer { try? h.close() }
        var m = TranscriptMeta()
        let head = (try? h.read(upToCount: 64 << 10)) ?? Data()
        var titles: [String: String] = [:]
        func lines(_ data: Data, dropFirst: Bool) -> [[String: Any]] {
            var parts = data.split(separator: 0x0A, omittingEmptySubsequences: true)
            if dropFirst, !parts.isEmpty { parts.removeFirst() }
            if data.last != 0x0A, !parts.isEmpty { parts.removeLast() }   // cut mid-line
            return parts.compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
        }
        func noteTitle(_ o: [String: Any]) {
            switch o["type"] as? String {
            case "custom-title": if let t = o["customTitle"] as? String, !t.isEmpty { titles["custom"] = t }
            case "ai-title": if let t = (o["aiTitle"] ?? o["title"]) as? String, !t.isEmpty { titles["ai"] = t }
            case "summary": if let t = o["summary"] as? String, !t.isEmpty { titles["summary"] = t }
            case "agent-name": if let t = o["agentName"] as? String, !t.isEmpty { titles["agent"] = t }
            default: break
            }
        }
        for o in lines(head, dropFirst: false) {
            if m.entrypoint == nil, let e = o["entrypoint"] as? String { m.entrypoint = e }
            if m.cwd == nil, let c = o["cwd"] as? String, !c.isEmpty { m.cwd = c }
            noteTitle(o)
            guard o["type"] as? String == "user", o["isMeta"] as? Bool != true, o["isSidechain"] as? Bool != true else { continue }
            m.hasUser = true
            if m.firstPrompt == nil, let text = promptText(o) { m.firstPrompt = text }
        }
        if size > UInt64(head.count) {
            let start = size > 256 << 10 ? size - (256 << 10) : UInt64(head.count)
            try? h.seek(toOffset: start)
            let tail = (try? h.readToEnd()) ?? Data()
            for o in lines(tail, dropFirst: start > UInt64(head.count)) {
                noteTitle(o)
                if !m.hasUser, o["type"] as? String == "user", o["isMeta"] as? Bool != true { m.hasUser = true }
            }
        }
        m.title = titles["custom"] ?? titles["ai"] ?? titles["summary"] ?? titles["agent"]
        return m
    }

    /// The text of a typed prompt; nil for tool results, commands and injected reminders.
    static func promptText(_ o: [String: Any]) -> String? {
        let content = (o["message"] as? [String: Any])?["content"]
        var text: String?
        if let s = content as? String { text = s }
        else if let blocks = content as? [[String: Any]] {
            if blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return nil }
            text = blocks.first { $0["type"] as? String == "text" }?["text"] as? String
        }
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !t.hasPrefix("<") else { return nil }
        return t
    }

    /// The pid is running and started no later than the session did (else it's a recycled pid).
    static func processAlive(_ e: RegistryEntry) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, e.pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == e.pid else { return false }
        guard let started = e.startedAt else { return true }
        let tv = info.kp_proc.p_un.__p_starttime
        let procStart = Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
        return procStart <= started.addingTimeInterval(60)
    }
}
