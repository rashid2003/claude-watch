import Foundation

public struct MoveError: Error, CustomStringConvertible, Sendable {
    public var description: String
    public var conflict: Bool
    init(_ description: String, conflict: Bool = false) { self.description = description; self.conflict = conflict }
}

/// Where transcripts and move backups live (injectable for tests).
public struct MoverRoots: Sendable {
    public var projects: URL
    public var backups: URL
    public init(projects: URL, backups: URL) { self.projects = projects; self.backups = backups }
    public static var live: MoverRoots {
        MoverRoots(projects: Paths.projects, backups: Paths.support.appendingPathComponent("moves"))
    }
}

/// Moves a desktop chat record between profiles / accounts / orgs. Callers make sure
/// neither window is running: a running Claude window rewrites its session folder.
public enum SessionMover {
    static let archiveIndex = "archived-sessions.idx"

    /// Claude Code's project folder name for a cwd: every non-alphanumeric character becomes "-".
    public static func projectKey(_ path: String) -> String {
        String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    static func resolve(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func folder(_ loc: ChatLocation, _ profile: Profile) -> URL {
        profile.dataDir.appendingPathComponent("claude-code-sessions/\(loc.accountUuid)/\(loc.orgUuid)")
    }

    static func subdirectories(_ url: URL) -> [String] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).filter { name in
            var isDir: ObjCBool = false
            return !name.hasPrefix(".") && fm.fileExists(atPath: url.appendingPathComponent(name).path, isDirectory: &isDir) && isDir.boolValue
        }.sorted()
    }

    static func recordFiles(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("local_") && $0.hasSuffix(".json") }
    }

    /// Every account/org folder of every profile.
    public static func locations(profiles: [Profile], config: Config) -> [ChatLocation] {
        var out: [ChatLocation] = []
        for p in profiles {
            let root = p.dataDir.appendingPathComponent("claude-code-sessions")
            for a in subdirectories(root) {
                for o in subdirectories(root.appendingPathComponent(a)) {
                    let org = config.orgNames[o] ?? String(o.prefix(8))
                    out.append(ChatLocation(profileId: p.id, accountUuid: a, orgUuid: o, profileName: p.name,
                                            label: p.name + " · " + org,
                                            chatCount: recordFiles(root.appendingPathComponent("\(a)/\(o)")).count))
                }
            }
        }
        return out
    }

    /// Where a chat in `from` can go: every other folder except the main-app profile.
    public static func destinations(for from: ChatLocation, in all: [ChatLocation]) -> [ChatLocation] {
        all.filter { $0.id != from.id && $0.profileId != "default" }
    }

    static func readArchived(_ dir: URL) -> [String] {
        JSONFile.object(at: dir.appendingPathComponent(archiveIndex))?["archived"] as? [String] ?? []
    }

    static func writeArchived(_ ids: [String], _ dir: URL) throws {
        try JSONSerialization.data(withJSONObject: ["v": 1, "archived": ids] as [String: Any])
            .write(to: dir.appendingPathComponent(archiveIndex), options: .atomic)
    }

    /// All chats in one folder, newest first. Reads every record, so call it off the main thread.
    public static func listChats(at loc: ChatLocation, profile: Profile) -> [ChatRecord] {
        let dir = folder(loc, profile)
        let archived = Set(readArchived(dir))
        return recordFiles(dir).compactMap { f -> ChatRecord? in
            autoreleasepool {
                guard let d = JSONFile.object(at: dir.appendingPathComponent(f)), let id = d["sessionId"] as? String else { return nil }
                let cwd = d["cwd"] as? String ?? ""
                return ChatRecord(
                    id: id, cliSessionId: d["cliSessionId"] as? String,
                    title: (d["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (cwd as NSString).lastPathComponent,
                    cwd: cwd, lastActivityAt: JSONFile.date(ms: d["lastActivityAt"]) ?? .distantPast,
                    isArchived: (d["isArchived"] as? Bool ?? false) || archived.contains(id), location: loc)
            }
        }.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }
}
