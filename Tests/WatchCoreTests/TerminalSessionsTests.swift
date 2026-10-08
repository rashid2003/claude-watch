import XCTest
@testable import WatchCore

final class TerminalSessionsTests: XCTestCase {
    var dir: URL!
    var registry: URL { dir.appendingPathComponent("sessions") }
    var projects: URL { dir.appendingPathComponent("projects") }

    let termId = "11111111-1111-4111-8111-111111111111"
    let desktopId = "22222222-2222-4222-8222-222222222222"
    let orphanDesktopId = "33333333-3333-4333-8333-333333333333"
    let scriptId = "44444444-4444-4444-8444-444444444444"
    let oldId = "55555555-5555-4555-8555-555555555555"

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ts-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: projects.appendingPathComponent("-Users-me-app"), withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func line(_ o: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), as: UTF8.self)
    }

    func user(_ text: String, entrypoint: String, cwd: String = "/Users/me/app", meta: Bool = false) -> String {
        var o: [String: Any] = ["type": "user", "entrypoint": entrypoint, "cwd": cwd, "timestamp": "2026-10-09T10:00:00.000Z",
                                "message": ["role": "user", "content": text]]
        if meta { o["isMeta"] = true }
        return line(o)
    }

    @discardableResult
    func transcript(_ id: String, _ lines: [String], age: TimeInterval = 60) -> URL {
        let url = projects.appendingPathComponent("-Users-me-app").appendingPathComponent(id + ".jsonl")
        try! (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    func register(pid: Int32, _ fields: [String: Any]) {
        var o = fields
        o["pid"] = pid
        try! line(o).write(to: registry.appendingPathComponent("\(pid).json"), atomically: true, encoding: .utf8)
    }

    func testFindsTerminalChatsAndSkipsDesktopAndScripts() {
        transcript(termId, [
            line(["type": "queue-operation", "operation": "enqueue"]),
            user("<system-reminder>ignore me</system-reminder>", entrypoint: "cli", meta: true),
            user("Fix the login bug\nand add tests", entrypoint: "cli"),
            line(["type": "assistant", "message": ["content": [["type": "text", "text": "ok"]]]]),
        ])
        transcript(desktopId, [user("desktop chat", entrypoint: "claude-desktop")])
        transcript(orphanDesktopId, [user("record gone", entrypoint: "claude-desktop")])
        transcript(scriptId, [user("summarise", entrypoint: "sdk-cli")])
        transcript(oldId, [user("old", entrypoint: "cli")], age: 9 * 86400)

        let index = TerminalSessionIndex(registryDir: registry, projectsDir: projects, isAlive: { _ in false })
        let found = index.sessions(excluding: [desktopId], live: [], accountUuid: "acct/org")
        XCTAssertEqual(found.map(\.id), [termId])
        let s = found[0]
        XCTAssertEqual(s.cliSessionId, termId)
        XCTAssertEqual(s.profileId, Profile.terminalId)
        XCTAssertEqual(s.accountUuid, "acct/org")
        XCTAssertEqual(s.title, "Fix the login bug")
        XCTAssertEqual(s.cwd, "/Users/me/app")
        XCTAssertEqual(s.isTerminal, true)
        XCTAssertTrue(s.isTerminalChat)
        XCTAssertNil(s.openInTerminal)
    }

    func testTitlePrefersCustomTitleAndLiveRegistryMarksItOpen() {
        transcript(termId, [
            user("first prompt", entrypoint: "cli"),
            line(["type": "custom-title", "customTitle": "Login bug", "sessionId": termId]),
            line(["type": "custom-title", "customTitle": "Login bug, round two", "sessionId": termId]),
        ])
        // Our own background reply of the same chat and a desktop run don't count as "open".
        register(pid: 101, ["sessionId": termId, "cwd": "/Users/me/app", "entrypoint": "cli", "kind": "interactive",
                            "status": "busy", "startedAt": 1_791_000_000_000, "updatedAt": 1_791_000_100_000])
        register(pid: 102, ["sessionId": desktopId, "cwd": "/x", "entrypoint": "claude-desktop",
                            "hostSessionId": "local_abc", "kind": "interactive"])
        register(pid: 103, ["sessionId": scriptId, "cwd": "/x", "entrypoint": "sdk-cli"])
        try! "{not json".write(to: registry.appendingPathComponent("104.json"), atomically: true, encoding: .utf8)
        try! "{}".write(to: registry.appendingPathComponent("105.key"), atomically: true, encoding: .utf8)

        let index = TerminalSessionIndex(registryDir: registry, projectsDir: projects, isAlive: { $0.pid != 103 })
        XCTAssertEqual(Set(index.registry().map(\.pid)), [101, 102, 103])
        let live = index.liveEntries()
        XCTAssertEqual(live.map(\.pid), [101], "desktop entries and dead pids are left out")
        XCTAssertEqual(live[0].status, "busy")
        XCTAssertTrue(live[0].isInteractive)

        let s = index.sessions(excluding: [], live: live, accountUuid: "a/o")
        XCTAssertEqual(s.map(\.id), [termId])
        XCTAssertEqual(s[0].title, "Login bug, round two")
        XCTAssertEqual(s[0].openInTerminal, true)
    }

    func testRegistryEntryKinds() {
        let desktop = RegistryEntry.parse(["pid": 5, "sessionId": "s", "entrypoint": "claude-desktop", "hostSessionId": "local_1"])
        XCTAssertEqual(desktop?.isDesktop, true)
        let cli = RegistryEntry.parse(["pid": 6, "sessionId": "s", "entrypoint": "cli", "kind": "interactive"])
        XCTAssertEqual(cli?.isDesktop, false)
        XCTAssertEqual(cli?.isInteractive, true)
        XCTAssertEqual(RegistryEntry.parse(["pid": 7, "sessionId": "s", "entrypoint": "sdk-cli"])?.isInteractive, false)
        XCTAssertNil(RegistryEntry.parse(["sessionId": "s"]), "no pid")
        // Defensive: no entrypoint and no host session counts as a terminal.
        XCTAssertEqual(RegistryEntry.parse(["pid": 8, "sessionId": "s"])?.isDesktop, false)
    }

    func testProcessAliveChecksPidAndStartTime() {
        let me = getpid()
        XCTAssertTrue(TerminalSessionIndex.processAlive(RegistryEntry(pid: me, sessionId: "s", cwd: "", startedAt: Date())))
        // A session that "started" long before this process did: the pid was recycled.
        XCTAssertFalse(TerminalSessionIndex.processAlive(RegistryEntry(pid: me, sessionId: "s", cwd: "",
                                                                        startedAt: Date(timeIntervalSince1970: 1_000_000))))
        XCTAssertFalse(TerminalSessionIndex.processAlive(RegistryEntry(pid: 999_999, sessionId: "s", cwd: "")))
    }

    func testCLIAccountFromClaudeJSON() throws {
        let url = dir.appendingPathComponent(".claude.json")
        try line(["numStartups": 3, "oauthAccount": ["accountUuid": "acc-1", "organizationUuid": "org-9",
                                                      "emailAddress": "me@example.com"]])
            .write(to: url, atomically: true, encoding: .utf8)
        let a = try XCTUnwrap(CLIAccount.read(from: url))
        XCTAssertEqual(a.identity, "acc-1/org-9")
        XCTAssertEqual(a.email, "me@example.com")
        try line(["numStartups": 3]).write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(CLIAccount.read(from: url), "not signed in")
        XCTAssertNil(CLIAccount.read(from: dir.appendingPathComponent("missing.json")))
    }

    func testTerminalJoinsTheAccountTheCLIIsSignedInto() {
        let work = Profile(id: "account-1", name: "Work", dataDir: URL(fileURLWithPath: "/tmp/w"))
        let home = Profile(id: "account-2", name: "Home", dataDir: URL(fileURLWithPath: "/tmp/h"))
        var accounts = ["account-1": "acc-1/org-9", "account-2": "acc-2/org-2", Profile.terminalId: "acc-1/org-9"]
        var groups = Monitor.accountGroups([work, home, .terminal], accounts: accounts)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].members.map(\.id), ["account-1", Profile.terminalId])

        // Signed into an account no desktop window uses (or not signed in): its own "Terminal" account.
        accounts[Profile.terminalId] = "acc-3/org-3"
        groups = Monitor.accountGroups([work, home, .terminal], accounts: accounts)
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[2].key, "acc-3/org-3")
        XCTAssertEqual(groups[2].members.map(\.id), [Profile.terminalId])
    }

    // MARK: Several CLI config dirs

    /// A fake home: `name` dirs with an optional login (`<dir>/.claude.json`, or `~/.claude.json` for
    /// `.claude`) and optional `projects/`.
    @discardableResult
    func makeDir(_ home: URL, _ name: String, account: String? = nil, org: String? = nil, projects: Bool = false) throws -> URL {
        let fm = FileManager.default
        let d = home.appendingPathComponent(name)
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        if projects { try fm.createDirectory(at: d.appendingPathComponent("projects/-Users-me-app"), withIntermediateDirectories: true) }
        if let account {
            let file = name == ".claude" ? home.appendingPathComponent(".claude.json") : d.appendingPathComponent(".claude.json")
            var oa: [String: Any] = ["accountUuid": account, "emailAddress": "\(account)@example.com"]
            if let org { oa["organizationUuid"] = org; oa["organizationName"] = "Org \(org)" }
            try line(["oauthAccount": oa]).write(to: file, atomically: true, encoding: .utf8)
        }
        return d
    }

    func testDiscoversEveryCLIConfigDir() throws {
        let home = dir.appendingPathComponent("home")
        try makeDir(home, ".claude", account: "acc-2", org: "org-h", projects: true)
        try makeDir(home, ".claude-1", account: "acc-2", org: "org-p")
        try makeDir(home, ".claude-3", projects: true)                      // transcripts, signed out since
        try makeDir(home, ".claude-4")                                      // never signed in: not yet
        let science = try makeDir(home, ".claude-science", projects: false) // another tool's data
        try line(["numStartups": 1]).write(to: science.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        try "x".write(to: home.appendingPathComponent(".claude-notes"), atomically: true, encoding: .utf8)

        let dirs = CLIConfigDir.discover(home: home, env: [:])
        XCTAssertEqual(dirs.map(\.shortName), ["claude", "claude-1", "claude-3"])
        XCTAssertEqual(dirs.map(\.profileId), [Profile.terminalId, "terminal:claude-1", "terminal:claude-3"])
        XCTAssertEqual(dirs.map(\.isDefault), [true, false, false])
        XCTAssertEqual(dirs[0].accountFile, home.appendingPathComponent(".claude.json"))
        XCTAssertEqual(dirs[1].accountFile, home.appendingPathComponent(".claude-1/.claude.json"))
        XCTAssertEqual(dirs[0].identity, "acc-2/org-h")
        XCTAssertEqual(dirs[1].identity, "acc-2/org-p")
        XCTAssertEqual(dirs[1].account?.email, "acc-2@example.com")
        XCTAssertEqual(dirs[1].account?.orgName, "Org org-p")
        XCTAssertNil(dirs[2].account)
        XCTAssertEqual(dirs[2].identity, "terminal:claude-3", "signed out: its own account")
        XCTAssertEqual(dirs.map(\.env), [nil, home.appendingPathComponent(".claude-1").path, home.appendingPathComponent(".claude-3").path])
        XCTAssertEqual(dirs[1].profile.name, "Terminal (claude-1)")
        XCTAssertTrue(dirs.allSatisfy { $0.profile.isTerminal })

        // CLAUDE_CONFIG_DIR makes another dir the default; ~/.claude then is one of the others.
        let moved = CLIConfigDir.discover(home: home, env: ["CLAUDE_CONFIG_DIR": home.appendingPathComponent(".claude-1").path])
        XCTAssertEqual(moved.map(\.profileId), [Profile.terminalId, "terminal:claude", "terminal:claude-3"])
        XCTAssertEqual(moved[0].identity, "acc-2/org-p")
        XCTAssertEqual(moved[1].identity, "acc-2/org-h")
        XCTAssertNil(moved[1].env, "~/.claude runs with CLAUDE_CONFIG_DIR unset")

        // A fresh Mac: just the default dir, not signed in.
        let empty = CLIConfigDir.discover(home: dir.appendingPathComponent("nobody"), env: [:])
        XCTAssertEqual(empty.map(\.profileId), [Profile.terminalId])
        XCTAssertNil(empty[0].account)

        XCTAssertEqual(CLIConfigDir.profile(id: "terminal:claude-1", home: home, env: [:])?.dataDir.lastPathComponent, ".claude-1")
        XCTAssertEqual(CLIConfigDir.profile(id: Profile.terminalId, home: home, env: [:])?.dataDir.lastPathComponent, ".claude")
        XCTAssertNil(CLIConfigDir.profile(id: "terminal:claude-4", home: home, env: [:]))
        XCTAssertNil(CLIConfigDir.profile(id: "account-1", home: home, env: [:]))
    }

    func testTerminalIds() {
        XCTAssertTrue(Profile.isTerminalId("terminal"))
        XCTAssertTrue(Profile.isTerminalId("terminal:claude-1"))
        XCTAssertFalse(Profile.isTerminalId("terminals"))
        XCTAssertFalse(Profile.isTerminalId("account-1"))
        var s = TerminalSessionIndex.info(id: termId, meta: TranscriptMeta(), mtime: Date(), entry: nil,
                                          accountUuid: "a", profileId: "terminal:claude-3")
        XCTAssertEqual(s.profileId, "terminal:claude-3")
        s.isTerminal = nil   // from an older Mac: the profile id alone says so
        XCTAssertTrue(s.isTerminalChat)
    }

    func testChatsAreFiledUnderTheirDirAndNeverDuplicated() throws {
        let home = dir.appendingPathComponent("home")
        try makeDir(home, ".claude", account: "acc-2", org: "org-h", projects: true)
        try makeDir(home, ".claude-1", account: "acc-2", org: "org-p", projects: true)
        let dirs = CLIConfigDir.discover(home: home, env: [:])
        func put(_ d: CLIConfigDir, _ id: String, age: TimeInterval) {
            let url = d.projects.appendingPathComponent("-Users-me-app/\(id).jsonl")
            try! (user("hi from \(d.shortName)", entrypoint: "cli") + "\n").write(to: url, atomically: true, encoding: .utf8)
            try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        put(dirs[0], termId, age: 60)
        put(dirs[1], scriptId, age: 60)
        // A chat copied between the dirs: the newer transcript (here ~/.claude-1's) owns it.
        put(dirs[0], oldId, age: 600)
        put(dirs[1], oldId, age: 30)

        let perDir = dirs.map { d -> (profileId: String, sessions: [SessionInfo], live: [RegistryEntry]) in
            let live = [RegistryEntry(pid: 7, sessionId: oldId, cwd: "/Users/me/app", status: "busy")]
            return (d.profileId, TerminalSessionIndex(d, isAlive: { _ in true })
                .sessions(excluding: [], live: [], accountUuid: d.identity, profileId: d.profileId), live)
        }
        let merged = CLIConfigDir.merge(perDir)
        let byId = Dictionary(uniqueKeysWithValues: merged.sessions.map { ($0.id, $0) })
        XCTAssertEqual(merged.sessions.count, 3)
        XCTAssertEqual(byId[termId]?.profileId, Profile.terminalId)
        XCTAssertEqual(byId[termId]?.accountUuid, "acc-2/org-h")
        XCTAssertEqual(byId[scriptId]?.profileId, "terminal:claude-1")
        XCTAssertEqual(byId[scriptId]?.accountUuid, "acc-2/org-p")
        XCTAssertEqual(byId[oldId]?.profileId, "terminal:claude-1")
        XCTAssertEqual(byId[oldId]?.title, "hi from claude-1")
        XCTAssertEqual(merged.live.count, 1, "only the owning dir's registry entry")

        // The transcript scanner reads the same dir's file for it.
        let located = TranscriptScanner.locate(dirs.map(\.projects))
        let real: (URL?) -> String? = { $0?.resolvingSymlinksInPath().path }
        XCTAssertEqual(real(located[oldId]?.first), real(dirs[1].projects.appendingPathComponent("-Users-me-app/\(oldId).jsonl")))
        XCTAssertEqual(real(located[termId]?.first?.deletingLastPathComponent().deletingLastPathComponent()), real(dirs[0].projects))
        XCTAssertNotNil(located[scriptId])
    }

    func testEachDirsTerminalJoinsItsOwnAccount() {
        let personal = Profile(id: "account-1", name: "Personal", dataDir: URL(fileURLWithPath: "/tmp/p"))
        let hamagan = Profile(id: "account-2", name: "Hamagan", dataDir: URL(fileURLWithPath: "/tmp/h"))
        let t1 = Profile(id: "terminal:claude-1", name: "Terminal (claude-1)", dataDir: URL(fileURLWithPath: "/tmp/.claude-1"))
        let t3 = Profile(id: "terminal:claude-3", name: "Terminal (claude-3)", dataDir: URL(fileURLWithPath: "/tmp/.claude-3"))
        let accounts = ["account-1": "acc-1/org-p", "account-2": "acc-1/org-h", Profile.terminalId: "acc-1/org-h",
                        "terminal:claude-1": "acc-1/org-p", "terminal:claude-3": "acc-3/org-h"]
        let groups = Monitor.accountGroups([personal, hamagan, .terminal, t1, t3], accounts: accounts)
        XCTAssertEqual(groups.map(\.key), ["acc-1/org-p", "acc-1/org-h", "acc-3/org-h"])
        XCTAssertEqual(groups[0].members.map(\.id), ["account-1", "terminal:claude-1"])
        XCTAssertEqual(groups[1].members.map(\.id), ["account-2", Profile.terminalId])
        XCTAssertEqual(groups[2].members.map(\.id), ["terminal:claude-3"], "no desktop window on that account")
    }

    func testTerminalProfileHasNoWindow() {
        let inst = [ClaudeProcesses.Instance(pid: 42, dataDir: nil), ClaudeProcesses.Instance(pid: 43, dataDir: Paths.claudeHome.path)]
        XCTAssertNil(ClaudeProcesses.pid(for: .terminal, in: inst))
    }
}
