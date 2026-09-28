import Foundation

enum JSONFile {
    static func object(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    static func date(ms value: Any?) -> Date? {
        guard let n = value as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: n.doubleValue / 1000)
    }
}

public enum UsageHistoryReader {
    /// Samples written by the desktop app (~every 15 min while it runs), oldest first.
    public static func read(profile: Profile) -> [UsageSample] {
        guard let obj = JSONFile.object(at: profile.dataDir.appendingPathComponent("plan-usage-history.json")),
              let samples = obj["samples"] as? [[String: Any]] else { return [] }
        return samples.compactMap { s in
            guard let t = JSONFile.date(ms: s["t"]), let u = s["u"] as? [String: Any] else { return nil }
            return UsageSample(t: t, org: s["org"] as? String ?? "",
                               fiveHour: (u["fh"] as? NSNumber)?.doubleValue ?? 0,
                               weekly: (u["sd"] as? NSNumber)?.doubleValue ?? 0)
        }.sorted { $0.t < $1.t }
    }
}

/// Reads desktop session records, re-parsing only files whose mtime changed.
public final class SessionIndex {
    private var cache: [String: (mtime: Date, info: SessionInfo?)] = [:]

    public init() {}

    public func sessions(for profile: Profile) -> [SessionInfo] {
        let fm = FileManager.default
        let root = profile.dataDir.appendingPathComponent("claude-code-sessions")
        var result: [SessionInfo] = []
        var seen = Set<String>()
        for account in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where !account.hasPrefix(".") {
            let accountDir = root.appendingPathComponent(account)
            for org in (try? fm.contentsOfDirectory(atPath: accountDir.path)) ?? [] where !org.hasPrefix(".") {
                let orgDir = accountDir.appendingPathComponent(org)
                for file in (try? fm.contentsOfDirectory(atPath: orgDir.path)) ?? []
                where file.hasPrefix("local_") && file.hasSuffix(".json") {
                    let url = orgDir.appendingPathComponent(file)
                    seen.insert(url.path)
                    let mtime = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
                    if let c = cache[url.path], c.mtime == mtime {
                        if let info = c.info { result.append(info) }
                        continue
                    }
                    // Records untouched for 8+ days can't affect status or the 7-day window.
                    var info: SessionInfo?
                    if Date().timeIntervalSince(mtime) < 8 * 86400 {
                        info = autoreleasepool { Self.parse(url: url, profileId: profile.id, accountUuid: account + "/" + org) }
                        info?.recordModifiedAt = mtime
                    }
                    cache[url.path] = (mtime, info)
                    if let info { result.append(info) }
                }
            }
        }
        cache = cache.filter { !$0.key.hasPrefix(root.path) || seen.contains($0.key) }
        return result.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    static func parse(url: URL, profileId: String, accountUuid: String) -> SessionInfo? {
        guard let d = JSONFile.object(at: url), let id = d["sessionId"] as? String else { return nil }
        let cwd = d["cwd"] as? String ?? ""
        let pending = (d["pendingToolPermissions"] as? [Any])?.isEmpty == false
        return SessionInfo(
            id: id,
            cliSessionId: d["cliSessionId"] as? String,
            priorCliSessionIds: d["priorCliSessionIds"] as? [String] ?? [],
            profileId: profileId,
            accountUuid: accountUuid,
            title: (d["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (cwd as NSString).lastPathComponent,
            cwd: cwd,
            model: d["model"] as? String,
            permissionMode: d["permissionMode"] as? String,
            lastActivityAt: JSONFile.date(ms: d["lastActivityAt"]) ?? .distantPast,
            isArchived: d["isArchived"] as? Bool ?? false,
            desktopError: d["error"] as? String,
            desktopErrorAt: JSONFile.date(ms: d["errorAt"]),
            hasPendingPermission: pending)
    }
}

public enum TaskReader {
    public static func tasks(cliSessionId: String) -> [TaskItem] {
        let dir = Paths.tasks.appendingPathComponent(cliSessionId)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }.compactMap { f -> TaskItem? in
            guard let d = JSONFile.object(at: dir.appendingPathComponent(f)),
                  let subject = d["subject"] as? String else { return nil }
            let status = TaskItem.Status(rawValue: d["status"] as? String ?? "") ?? .pending
            return TaskItem(id: d["id"] as? String ?? f, subject: subject,
                            activeForm: d["activeForm"] as? String, status: status)
        }.sorted { (Int($0.id) ?? 0, $0.id) < (Int($1.id) ?? 0, $1.id) }
    }
}
