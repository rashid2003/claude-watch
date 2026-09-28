import XCTest
@testable import WatchCore

final class ConfigMoveTests: XCTestCase {
    func testOrgNamesDecodeAndDefault() throws {
        let json = #"{"orgNames": {"793c": "Hamagan Technologies"}}"#
        let cfg = try JSONCoder.decoder.decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(cfg.orgNames["793c"], "Hamagan Technologies")
        XCTAssertEqual(try JSONCoder.decoder.decode(Config.self, from: Data("{}".utf8)).orgNames, [:])
    }

    func testChatLocationId() {
        let l = ChatLocation(profileId: "claude-2-x", accountUuid: "acc", orgUuid: "org")
        XCTAssertEqual(l.id, "claude-2-x/acc/org")
    }
}

/// Builds a fake tree: two profiles, one account/org folder each, plus projects and backups roots.
class MoveTreeCase: XCTestCase {
    var root: URL!
    var roots: MoverRoots!
    var p1: Profile!
    var p2: Profile!
    let a1 = "aaaaaaaa-0000-0000-0000-000000000001", o1 = "11111111-0000-0000-0000-000000000001"
    let a2 = "bbbbbbbb-0000-0000-0000-000000000002", o2 = "22222222-0000-0000-0000-000000000002"
    let fm = FileManager.default

    override func setUpWithError() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cw-move-" + UUID().uuidString)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        root = tmp.resolvingSymlinksInPath()
        p1 = Profile(id: "claude-1-one", name: "One", dataDir: root.appendingPathComponent("profiles/claude-1-one"), launcherApp: nil)
        p2 = Profile(id: "claude-2-two", name: "Two", dataDir: root.appendingPathComponent("profiles/claude-2-two"), launcherApp: nil)
        roots = MoverRoots(projects: root.appendingPathComponent("projects"), backups: root.appendingPathComponent("backups"))
        try fm.createDirectory(at: folder(p1, a1, o1), withIntermediateDirectories: true)
        try fm.createDirectory(at: folder(p2, a2, o2), withIntermediateDirectories: true)
        try fm.createDirectory(at: roots.projects, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        SessionMover.faultPoint = nil
        try? fm.removeItem(at: root)
    }

    func folder(_ p: Profile, _ a: String, _ o: String) -> URL {
        p.dataDir.appendingPathComponent("claude-code-sessions/\(a)/\(o)")
    }
    var from: ChatLocation { ChatLocation(profileId: p1.id, accountUuid: a1, orgUuid: o1) }
    var to: ChatLocation { ChatLocation(profileId: p2.id, accountUuid: a2, orgUuid: o2) }

    @discardableResult
    func writeRecord(_ id: String, cwd: String, archived: Bool = false) throws -> URL {
        let d: [String: Any] = [
            "sessionId": id, "cliSessionId": "cli-" + id, "title": "Chat " + id,
            "cwd": cwd, "originCwd": cwd, "lastActivityAt": 1_790_632_772_654, "isArchived": archived,
            "model": "claude-opus-5-5",
            "remoteMcpServersConfig": ["x": 1], "sessionPermissionUpdates": [["directories": ["/tmp"]]],
            "alwaysAllowedReasons": [], "toolSurfaceSnapshot": ["a": 1],
        ]
        let url = folder(p1, a1, o1).appendingPathComponent(id + ".json")
        try JSONSerialization.data(withJSONObject: d).write(to: url)
        return url
    }

    func json(_ url: URL) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
    }

    func writeIdx(_ ids: [String], _ dir: URL) throws {
        try JSONSerialization.data(withJSONObject: ["v": 1, "archived": ids])
            .write(to: dir.appendingPathComponent("archived-sessions.idx"))
    }
}

final class MoverListingTests: MoveTreeCase {
    func testProjectKey() {
        XCTAssertEqual(SessionMover.projectKey("/Users/r/Library/Application Support/Claude/x.y_z"),
                       "-Users-r-Library-Application-Support-Claude-x-y-z")
    }

    func testLocationsLabelsAndDestinations() throws {
        try writeRecord("local_1", cwd: "/tmp")
        let def = Profile(id: "default", name: "Claude", dataDir: root.appendingPathComponent("main"), launcherApp: nil)
        try fm.createDirectory(at: folder(def, a1, o1), withIntermediateDirectories: true)
        var cfg = Config()
        cfg.orgNames[o1] = "Org One"
        let locs = SessionMover.locations(profiles: [p1, p2, def], config: cfg)
        XCTAssertEqual(locs.count, 3)
        let l1 = locs.first { $0.profileId == p1.id }!
        XCTAssertEqual(l1.label, "One · Org One")
        XCTAssertEqual(l1.profileName, "One")
        XCTAssertEqual(l1.chatCount, 1)
        XCTAssertEqual(locs.first { $0.profileId == p2.id }!.label, "Two · 22222222")
        let dests = SessionMover.destinations(for: l1, in: locs)
        XCTAssertEqual(dests.map(\.profileId), [p2.id])   // not itself, not "default"
    }

    func testListChatsReadsArchivedFromIndex() throws {
        try writeRecord("local_1", cwd: "/tmp/a")
        try writeRecord("local_2", cwd: "/tmp/b")
        try writeIdx(["local_2"], folder(p1, a1, o1))
        let chats = SessionMover.listChats(at: from, profile: p1)
        XCTAssertEqual(Set(chats.map(\.id)), ["local_1", "local_2"])
        XCTAssertEqual(chats.first { $0.id == "local_2" }?.isArchived, true)
        XCTAssertEqual(chats.first { $0.id == "local_1" }?.title, "Chat local_1")
    }
}

final class MoverExecuteTests: MoveTreeCase {
    func testPlainMoveStripsAccountKeysAndKeepsProjectCwd() throws {
        let src = try writeRecord("local_1", cwd: "/Users/x/Development/proj")
        let r = try SessionMover.execute(sessionId: "local_1", from: from, to: to, profiles: [p1, p2], roots: roots)
        let dst = folder(p2, a2, o2).appendingPathComponent("local_1.json")
        XCTAssertFalse(fm.fileExists(atPath: src.path))
        let d = json(dst)
        XCTAssertEqual(d["cwd"] as? String, "/Users/x/Development/proj")
        XCTAssertEqual(d["model"] as? String, "claude-opus-5-5")
        for k in ["remoteMcpServersConfig", "sessionPermissionUpdates", "alwaysAllowedReasons", "toolSurfaceSnapshot"] {
            XCTAssertNil(d[k], k)
        }
        XCTAssertNil(r.newCwd)
        XCTAssertTrue(fm.fileExists(atPath: r.backupDir.appendingPathComponent("record.json").path))
        XCTAssertTrue(fm.fileExists(atPath: r.backupDir.appendingPathComponent("move.json").path))
    }

    func testConflictLeavesSourceAlone() throws {
        let src = try writeRecord("local_1", cwd: "/tmp")
        try Data("{}".utf8).write(to: folder(p2, a2, o2).appendingPathComponent("local_1.json"))
        XCTAssertThrowsError(try SessionMover.execute(sessionId: "local_1", from: from, to: to, profiles: [p1, p2], roots: roots)) {
            XCTAssertTrue(($0 as? MoveError)?.conflict == true)
        }
        XCTAssertTrue(fm.fileExists(atPath: src.path))
        XCTAssertEqual(json(folder(p2, a2, o2).appendingPathComponent("local_1.json")).count, 0)
    }

    func testArchivedChatMovesBetweenIndexes() throws {
        try writeRecord("local_1", cwd: "/tmp", archived: true)
        try writeRecord("local_2", cwd: "/tmp", archived: true)
        try writeIdx(["local_1", "local_2"], folder(p1, a1, o1))
        _ = try SessionMover.execute(sessionId: "local_1", from: from, to: to, profiles: [p1, p2], roots: roots)
        XCTAssertEqual(SessionMover.readArchived(folder(p1, a1, o1)), ["local_2"])
        XCTAssertEqual(SessionMover.readArchived(folder(p2, a2, o2)), ["local_1"])
    }

    func testFailureAfterRemoveRollsEverythingBack() throws {
        let src = try writeRecord("local_1", cwd: "/tmp", archived: true)
        try writeIdx(["local_1"], folder(p1, a1, o1))
        let before = try Data(contentsOf: src)
        SessionMover.faultPoint = "end"
        XCTAssertThrowsError(try SessionMover.execute(sessionId: "local_1", from: from, to: to, profiles: [p1, p2], roots: roots))
        XCTAssertEqual(try Data(contentsOf: src), before)
        XCTAssertFalse(fm.fileExists(atPath: folder(p2, a2, o2).appendingPathComponent("local_1.json").path))
        XCTAssertEqual(SessionMover.readArchived(folder(p1, a1, o1)), ["local_1"])
        XCTAssertFalse(fm.fileExists(atPath: folder(p2, a2, o2).appendingPathComponent("archived-sessions.idx").path))
    }

    func testUnreadableDestIndexAbortsBeforeAnyChange() throws {
        let src = try writeRecord("local_1", cwd: "/tmp", archived: true)
        let idx = folder(p2, a2, o2).appendingPathComponent("archived-sessions.idx")
        try Data("not json".utf8).write(to: idx)
        XCTAssertThrowsError(try SessionMover.execute(sessionId: "local_1", from: from, to: to, profiles: [p1, p2], roots: roots)) {
            XCTAssertTrue("\($0)".contains("unreadable"))
        }
        XCTAssertTrue(fm.fileExists(atPath: src.path))
        XCTAssertEqual(try Data(contentsOf: idx), Data("not json".utf8))
        XCTAssertFalse(fm.fileExists(atPath: folder(p2, a2, o2).appendingPathComponent("local_1.json").path))
    }

    func testIndexUpdateKeepsOtherKeys() throws {
        try writeRecord("local_1", cwd: "/tmp", archived: true)
        let dstDir = folder(p2, a2, o2)
        try JSONSerialization.data(withJSONObject: ["v": 7, "archived": ["local_9"], "extra": "keep"] as [String: Any])
            .write(to: dstDir.appendingPathComponent("archived-sessions.idx"))
        _ = try SessionMover.execute(sessionId: "local_1", from: from, to: to, profiles: [p1, p2], roots: roots)
        let d = json(dstDir.appendingPathComponent("archived-sessions.idx"))
        XCTAssertEqual(d["archived"] as? [String], ["local_9", "local_1"])
        XCTAssertEqual(d["extra"] as? String, "keep")
        XCTAssertEqual(d["v"] as? Int, 7)
    }

    func testAfterWriteFaultRollsBackCleanlyAndStoreKeepsBackupDir() throws {
        let src = try writeRecord("local_1", cwd: "/tmp")
        let before = try Data(contentsOf: src)
        SessionMover.faultPoint = "afterWrite"
        XCTAssertThrowsError(try SessionMover.execute(sessionId: "local_1", from: from, to: to, profiles: [p1, p2], roots: roots)) {
            XCTAssertNotNil(($0 as? MoveError)?.backupDir)
        }
        XCTAssertEqual(try Data(contentsOf: src), before)
        XCTAssertFalse(fm.fileExists(atPath: folder(p2, a2, o2).appendingPathComponent("local_1.json").path))

        let store = MoveStore(url: root.appendingPathComponent("moves.json"), roots: roots)
        store.add(sessionId: "local_1", title: "t", from: from, to: to)
        let r = store.runDue(profiles: [p1, p2], running: [], liveSessions: [])
        XCTAssertEqual(r.first?.status, .failed)
        XCTAssertNotNil(store.all().first?.backupDir)
        XCTAssertTrue(fm.fileExists(atPath: store.all().first!.backupDir!))
    }

    func testWriteExclusive() throws {
        let url = root.appendingPathComponent("x.json")
        try SessionMover.writeExclusive(Data("one".utf8), to: url)
        XCTAssertEqual(try String(contentsOf: url), "one")
        XCTAssertThrowsError(try SessionMover.writeExclusive(Data("two".utf8), to: url)) {
            XCTAssertTrue(($0 as? MoveError)?.conflict == true)
        }
        XCTAssertEqual(try String(contentsOf: url), "one")
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: root.path).contains { $0.contains(".tmp-") })
    }

    func testBadSessionIdRejected() throws {
        XCTAssertThrowsError(try SessionMover.execute(sessionId: "local_../x", from: from, to: to, profiles: [p1, p2], roots: roots))
        XCTAssertFalse(fm.fileExists(atPath: roots.backups.path))
    }

    func testMissingRecordFails() {
        XCTAssertThrowsError(try SessionMover.execute(sessionId: "local_9", from: from, to: to, profiles: [p1, p2], roots: roots)) {
            XCTAssertEqual(($0 as? MoveError)?.conflict, false)
        }
    }
}

final class MoverScratchTests: MoveTreeCase {
    /// Scratch chat whose cwd is written through a symlinked profile name (like account-1 -> claude-3-…),
    /// with a transcript folder for each spelling; the resolved one is newer.
    func makeScratchChat() throws -> (aliasCwd: String, realCwd: String) {
        let real = p1.dataDir.appendingPathComponent("scratch-workspaces/\(a1)/\(o1)/scratch-1")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: real.appendingPathComponent("notes.txt"))
        let alias = root.appendingPathComponent("profiles/account-1")
        try fm.createSymbolicLink(at: alias, withDestinationURL: p1.dataDir)
        let aliasCwd = alias.appendingPathComponent("scratch-workspaces/\(a1)/\(o1)/scratch-1").path
        for (path, body, age) in [(aliasCwd, "old", 3600.0), (real.path, "new", 0.0)] {
            let dir = roots.projects.appendingPathComponent(SessionMover.projectKey(path))
            try fm.createDirectory(at: dir.appendingPathComponent("memory"), withIntermediateDirectories: true)
            let t = dir.appendingPathComponent("cli-local_1.jsonl")
            try Data(body.utf8).write(to: t)
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: t.path)
        }
        try writeRecord("local_1", cwd: aliasCwd)
        return (aliasCwd, real.path)
    }

    var newCwd: String {
        SessionMover.resolve(p2.dataDir.path) + "/scratch-workspaces/\(a2)/\(o2)/scratch-1"
    }

    func testScratchFolderAndNewestTranscriptMove() throws {
        let (aliasCwd, realCwd) = try makeScratchChat()
        let r = try SessionMover.execute(sessionId: "local_1", from: from, to: to, profiles: [p1, p2], roots: roots)
        XCTAssertEqual(r.newCwd, newCwd)
        XCTAssertEqual(try String(contentsOfFile: newCwd + "/notes.txt"), "hello")
        XCTAssertFalse(fm.fileExists(atPath: realCwd))
        let d = json(folder(p2, a2, o2).appendingPathComponent("local_1.json"))
        XCTAssertEqual(d["cwd"] as? String, newCwd)
        XCTAssertEqual(d["originCwd"] as? String, newCwd)
        let moved = roots.projects.appendingPathComponent(SessionMover.projectKey(newCwd))
        XCTAssertEqual(try String(contentsOf: moved.appendingPathComponent("cli-local_1.jsonl")), "new")
        XCTAssertTrue(fm.fileExists(atPath: moved.appendingPathComponent("memory").path))
        XCTAssertFalse(fm.fileExists(atPath: roots.projects.appendingPathComponent(SessionMover.projectKey(realCwd)).path))
        XCTAssertFalse(fm.fileExists(atPath: roots.projects.appendingPathComponent(SessionMover.projectKey(aliasCwd)).path))
        XCTAssertTrue(fm.fileExists(atPath: r.backupDir.appendingPathComponent(
            "stale-transcripts/" + SessionMover.projectKey(aliasCwd) + "/cli-local_1.jsonl").path))
    }

    func testScratchRollback() throws {
        let (aliasCwd, realCwd) = try makeScratchChat()
        SessionMover.faultPoint = "end"
        XCTAssertThrowsError(try SessionMover.execute(sessionId: "local_1", from: from, to: to, profiles: [p1, p2], roots: roots))
        XCTAssertEqual(try String(contentsOfFile: realCwd + "/notes.txt"), "hello")
        XCTAssertFalse(fm.fileExists(atPath: newCwd))
        for (path, body) in [(aliasCwd, "old"), (realCwd, "new")] {
            let t = roots.projects.appendingPathComponent(SessionMover.projectKey(path) + "/cli-local_1.jsonl")
            XCTAssertEqual(try String(contentsOf: t), body)
        }
        XCTAssertEqual(json(folder(p1, a1, o1).appendingPathComponent("local_1.json"))["cwd"] as? String, aliasCwd)
    }

    /// Chat whose cwd is `cwd` (created on disk) must move as a record only; nothing else may move.
    func assertRecordOnly(cwd: URL, keep: URL) throws {
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        try writeRecord("local_1", cwd: cwd.path)
        let r = try SessionMover.execute(sessionId: "local_1", from: from, to: to, profiles: [p1, p2], roots: roots)
        XCTAssertNil(r.newCwd)
        XCTAssertTrue(fm.fileExists(atPath: cwd.path))
        XCTAssertTrue(fm.fileExists(atPath: keep.path))
        XCTAssertEqual(json(folder(p2, a2, o2).appendingPathComponent("local_1.json"))["cwd"] as? String, cwd.path)
        XCTAssertFalse(fm.fileExists(atPath: p2.dataDir.appendingPathComponent("scratch-workspaces").path))
    }

    func testAccountFolderCwdMovesRecordOnly() throws {
        let acct = p1.dataDir.appendingPathComponent("scratch-workspaces/\(a1)")
        let s1 = acct.appendingPathComponent("\(o1)/scratch-1")
        try fm.createDirectory(at: s1, withIntermediateDirectories: true)
        try assertRecordOnly(cwd: acct, keep: s1)
    }

    func testOtherOrgScratchCwdMovesRecordOnly() throws {
        let x = p1.dataDir.appendingPathComponent("scratch-workspaces/\(a1)/other-org/scratch-x")
        try assertRecordOnly(cwd: x, keep: x)
    }

    func testNestedScratchCwdMovesRecordOnly() throws {
        let s1 = p1.dataDir.appendingPathComponent("scratch-workspaces/\(a1)/\(o1)/scratch-1")
        try assertRecordOnly(cwd: s1.appendingPathComponent("sub"), keep: s1)
    }

    func testMissingScratchFolderMovesRecordOnly() throws {
        let gone = p1.dataDir.appendingPathComponent("scratch-workspaces/\(a1)/\(o1)/scratch-gone").path
        try writeRecord("local_1", cwd: gone)
        let r = try SessionMover.execute(sessionId: "local_1", from: from, to: to, profiles: [p1, p2], roots: roots)
        XCTAssertNil(r.newCwd)
        XCTAssertEqual(json(folder(p2, a2, o2).appendingPathComponent("local_1.json"))["cwd"] as? String, gone)
    }
}

final class MoveStoreTests: MoveTreeCase {
    var store: MoveStore!
    override func setUpWithError() throws {
        try super.setUpWithError()
        store = MoveStore(url: root.appendingPathComponent("moves.json"), roots: roots)
    }

    func testAddRejectsSecondPendingMoveForSameChat() {
        XCTAssertNotNil(store.add(sessionId: "local_1", title: "t", from: from, to: to))
        XCTAssertNil(store.add(sessionId: "local_1", title: "t", from: from, to: to))
        XCTAssertEqual(store.pending.count, 1)
    }

    func testRunDueWaitsWhileAWindowRuns() throws {
        try writeRecord("local_1", cwd: "/tmp")
        store.add(sessionId: "local_1", title: "t", from: from, to: to)
        XCTAssertTrue(store.runDue(profiles: [p1, p2], running: [p2.id], liveSessions: []).isEmpty)
        XCTAssertTrue(store.runDue(profiles: [p1, p2], running: [], liveSessions: ["local_1"]).isEmpty)
        let done = store.runDue(profiles: [p1, p2], running: [], liveSessions: [])
        XCTAssertEqual(done.map(\.status), [.done])
        XCTAssertNotNil(done[0].backupDir)
        XCTAssertTrue(store.pending.isEmpty)
    }

    func testUndoMovesBackAndMarksOriginal() throws {
        try writeRecord("local_1", cwd: "/tmp")
        let m = store.add(sessionId: "local_1", title: "t", from: from, to: to)!
        _ = store.runDue(profiles: [p1, p2], running: [], liveSessions: [])
        let u = store.undo(moveId: m.id)!
        XCTAssertEqual(u.from.id, to.id)
        XCTAssertEqual(u.to.id, from.id)
        XCTAssertEqual(store.runDue(profiles: [p1, p2], running: [], liveSessions: []).map(\.status), [.done])
        XCTAssertTrue(fm.fileExists(atPath: folder(p1, a1, o1).appendingPathComponent("local_1.json").path))
        XCTAssertEqual(store.all().first { $0.id == m.id }?.status, .undone)
    }

    func testConflictIsRecorded() throws {
        try writeRecord("local_1", cwd: "/tmp")
        try Data("{}".utf8).write(to: folder(p2, a2, o2).appendingPathComponent("local_1.json"))
        store.add(sessionId: "local_1", title: "t", from: from, to: to)
        let r = store.runDue(profiles: [p1, p2], running: [], liveSessions: [])
        XCTAssertEqual(r.first?.status, .conflict)
        XCTAssertNotNil(r.first?.note)
    }

    func testCorruptStoreIsPreservedNotWiped() throws {
        try Data("garbage".utf8).write(to: store.url)
        XCTAssertTrue(store.all().isEmpty)
        XCTAssertEqual(try String(contentsOf: store.url), "garbage")
        let m = store.add(sessionId: "local_1", title: "t", from: from, to: to)
        XCTAssertNotNil(m)
        let files = try fm.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("moves.json.corrupt-") }
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(files[0])), "garbage")
        XCTAssertEqual(store.all().map(\.id), [m!.id])
    }

    func testCancel() {
        let m = store.add(sessionId: "local_1", title: "t", from: from, to: to)!
        store.cancel(id: m.id)
        XCTAssertTrue(store.all().isEmpty)
    }
}
