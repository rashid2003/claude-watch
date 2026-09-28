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

    /// Keys tied to the account/org the chat ran under; dropped when it moves.
    static let accountKeys = ["remoteMcpServersConfig", "sessionPermissionUpdates", "alwaysAllowedReasons", "toolSurfaceSnapshot"]

    /// Tests set this to make `execute` fail at a named step.
    static var faultPoint: String?
    static func fault(_ name: String) throws {
        if faultPoint == name { throw MoveError("injected fault at \(name)") }
    }

    public struct Outcome: Sendable {
        public var backupDir: URL
        public var newCwd: String?
    }

    static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: d)
    }

    /// Moves one chat record from `from` to `to`. All or nothing: on any error every
    /// change is undone and the source record is left as it was.
    public static func execute(sessionId: String, from: ChatLocation, to: ChatLocation, profiles: [Profile],
                               roots: MoverRoots = .live, now: Date = Date()) throws -> Outcome {
        let fm = FileManager.default
        guard let src = profiles.first(where: { $0.id == from.profileId }),
              let dst = profiles.first(where: { $0.id == to.profileId }) else { throw MoveError("window not found") }
        let srcDir = folder(from, src), dstDir = folder(to, dst)
        let srcURL = srcDir.appendingPathComponent(sessionId + ".json")
        let dstURL = dstDir.appendingPathComponent(sessionId + ".json")
        guard fm.fileExists(atPath: srcURL.path) else { throw MoveError("chat not found in \(from.label)") }
        guard !fm.fileExists(atPath: dstURL.path) else { throw MoveError("already in \(to.label)", conflict: true) }
        guard var rec = JSONFile.object(at: srcURL) else { throw MoveError("chat record unreadable") }

        // Backup first, so a move can always be undone by hand.
        let backup = roots.backups.appendingPathComponent(stamp(now) + "-" + sessionId)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        try fm.copyItem(at: srcURL, to: backup.appendingPathComponent("record.json"))
        let srcIdx = srcDir.appendingPathComponent(archiveIndex), dstIdx = dstDir.appendingPathComponent(archiveIndex)
        let srcIdxBackup = backup.appendingPathComponent("source-" + archiveIndex)
        let dstIdxBackup = backup.appendingPathComponent("dest-" + archiveIndex)
        if fm.fileExists(atPath: srcIdx.path) { try fm.copyItem(at: srcIdx, to: srcIdxBackup) }
        if fm.fileExists(atPath: dstIdx.path) { try fm.copyItem(at: dstIdx, to: dstIdxBackup) }
        try JSONSerialization.data(withJSONObject: ["sessionId": sessionId, "from": from.id, "to": to.id,
                                                    "at": Int(now.timeIntervalSince1970)] as [String: Any],
                                   options: [.prettyPrinted])
            .write(to: backup.appendingPathComponent("move.json"))

        var undo: [() -> Void] = []
        func restore(_ copy: URL, to url: URL) {
            try? fm.removeItem(at: url)
            if fm.fileExists(atPath: copy.path) { try? fm.copyItem(at: copy, to: url) }
        }
        do {
            for k in accountKeys { rec.removeValue(forKey: k) }
            var newCwd: String?
            if let cwd = rec["cwd"] as? String,
               let moved = try relocateScratch(cwd: cwd, src: src, dst: dst, to: to, roots: roots, backup: backup, undo: &undo) {
                if let origin = rec["originCwd"] as? String, resolve(origin) == resolve(cwd) { rec["originCwd"] = moved }
                rec["cwd"] = moved
                newCwd = moved
            }

            try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: rec).write(to: dstURL, options: .withoutOverwriting)
            undo.append { try? fm.removeItem(at: dstURL) }
            try fault("afterWrite")

            let srcArchived = readArchived(srcDir)
            if (rec["isArchived"] as? Bool ?? false) || srcArchived.contains(sessionId) {
                var ids = readArchived(dstDir)
                if !ids.contains(sessionId) { ids.append(sessionId) }
                try writeArchived(ids, dstDir)
                undo.append { restore(dstIdxBackup, to: dstIdx) }
            }
            if srcArchived.contains(sessionId) {
                try writeArchived(srcArchived.filter { $0 != sessionId }, srcDir)
                undo.append { restore(srcIdxBackup, to: srcIdx) }
            }

            try fm.removeItem(at: srcURL)
            undo.append { restore(backup.appendingPathComponent("record.json"), to: srcURL) }
            try fault("end")
            return Outcome(backupDir: backup, newCwd: newCwd)
        } catch {
            for u in undo.reversed() { u() }
            throw error
        }
    }

    /// Scratch-workspace chats get their folder moved with them, otherwise the source window
    /// may delete it once the chat is gone. Also moves the transcript folder so the CLI finds it
    /// under the new cwd. Returns the new cwd, or nil when nothing moved.
    static func relocateScratch(cwd: String, src: Profile, dst: Profile, to: ChatLocation,
                                roots: MoverRoots, backup: URL, undo: inout [() -> Void]) throws -> String? {
        let fm = FileManager.default
        let real = resolve(cwd)
        guard real.hasPrefix(resolve(src.dataDir.path) + "/scratch-workspaces/"), fm.fileExists(atPath: real) else { return nil }
        let name = (real as NSString).lastPathComponent
        let parent = URL(fileURLWithPath: resolve(dst.dataDir.path))
            .appendingPathComponent("scratch-workspaces/\(to.accountUuid)/\(to.orgUuid)")
        let newPath = parent.appendingPathComponent(name).path
        guard !fm.fileExists(atPath: newPath) else { throw MoveError("folder \(name) already in \(to.label)", conflict: true) }

        // One transcript folder per spelling of the old path; the CLI writes to the resolved one.
        let newDir = roots.projects.appendingPathComponent(projectKey(newPath))
        let oldDirs = Array(Set([projectKey(cwd), projectKey(real)]))
            .map { roots.projects.appendingPathComponent($0) }
            .filter { fm.fileExists(atPath: $0.path) }
        guard oldDirs.isEmpty || !fm.fileExists(atPath: newDir.path) else {
            throw MoveError("transcript folder for \(name) already exists", conflict: true)
        }

        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try fm.moveItem(atPath: real, toPath: newPath)
        undo.append { try? fm.moveItem(atPath: newPath, toPath: real) }

        let newest = oldDirs.max { latestWrite($0) < latestWrite($1) }
        for dir in oldDirs {
            let dest = dir == newest
                ? newDir
                : backup.appendingPathComponent("stale-transcripts/" + dir.lastPathComponent)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: dir, to: dest)
            undo.append { try? fm.moveItem(at: dest, to: dir) }
        }
        return newPath
    }

    /// Most recent modification time of the transcripts directly inside a project folder.
    static func latestWrite(_ dir: URL) -> Date {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".jsonl") }
            .compactMap { (try? fm.attributesOfItem(atPath: dir.appendingPathComponent($0).path))?[.modificationDate] as? Date }
            .max() ?? .distantPast
    }
}
