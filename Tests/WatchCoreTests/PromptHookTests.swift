import XCTest
@testable import WatchCore

final class PromptHookTests: XCTestCase {
    var dir: URL!
    var settings: URL { dir.appendingPathComponent("settings.json") }
    let cmd = PromptHookInstaller.command(cli: "/Applications/Session Watch.app/Contents/MacOS/claude-watch",
                                          socket: "/Users/me/Library/Application Support/claude-watch/bridge.sock")

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ph-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func json(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
    }

    func read() throws -> [String: Any] { try json(Data(contentsOf: settings)) }

    func backups() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".bak") }.sorted()
    }

    // MARK: Decision mapping

    func testDecisionOutput() throws {
        XCTAssertNil(PromptHook.output(.none), "no decision prints nothing")
        let allow = try json(PromptHook.output(.allow))
        let out = try XCTUnwrap(allow["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(out["hookEventName"] as? String, "PermissionRequest")
        XCTAssertEqual((out["decision"] as? [String: Any])?["behavior"] as? String, "allow")

        let deny = try json(PromptHook.output(.deny("not now")))
        let d = try XCTUnwrap((deny["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])
        XCTAssertEqual(d["behavior"] as? String, "deny")
        XCTAssertEqual(d["message"] as? String, "not now")
        let deny2 = try json(PromptHook.output(.deny(nil)))
        XCTAssertEqual(((deny2["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])?["message"] as? String,
                       "Denied from the phone")
    }

    func testBrokerReplyMapping() {
        XCTAssertEqual(PromptHook.decision(fromBroker: ["decision": "allow"]), .allow)
        XCTAssertEqual(PromptHook.decision(fromBroker: ["decision": "deny", "message": "m"]), .deny("m"))
        XCTAssertEqual(PromptHook.decision(fromBroker: ["decision": "defer"]), .none)
        XCTAssertEqual(PromptHook.decision(fromBroker: nil), .none, "app not running / timed out")
        XCTAssertEqual(PromptHook.decision(fromBroker: ["decision": "maybe"]), .none)
    }

    func testSkipsDesktopHeadlessAndScriptRuns() {
        let input: [String: Any] = ["hook_event_name": "PermissionRequest", "session_id": "s1", "tool_name": "Bash",
                                    "tool_input": ["command": "ls"]]
        XCTAssertFalse(PromptHook.shouldSkip(input: input, env: [:]))
        XCTAssertFalse(PromptHook.shouldSkip(input: input, env: ["CLAUDE_CODE_ENTRYPOINT": "cli"]))
        XCTAssertTrue(PromptHook.shouldSkip(input: input, env: ["CLAUDE_CODE_HOST_SESSION_ID": "local_1"]))
        XCTAssertTrue(PromptHook.shouldSkip(input: input, env: ["CLAUDE_CODE_ENTRYPOINT": "claude-desktop"]))
        XCTAssertTrue(PromptHook.shouldSkip(input: input, env: ["CLAUDE_CODE_ENTRYPOINT": "sdk-cli"]))
        XCTAssertTrue(PromptHook.shouldSkip(input: input, env: [HeadlessRunner.headlessEnv: "1"]))
        var other = input
        other["hook_event_name"] = "PreToolUse"
        XCTAssertTrue(PromptHook.shouldSkip(input: other, env: [:]))
        XCTAssertTrue(PromptHook.shouldSkip(input: ["hook_event_name": "PermissionRequest"], env: [:]), "no session")
    }

    func testRequestCarriesSummaryAndWait() {
        let r = PromptHook.request(input: ["session_id": "s1", "tool_name": "Bash", "tool_use_id": "toolu_1",
                                           "tool_input": ["command": "swift build", "description": "Build"]], wait: 120)
        XCTAssertEqual(r["sessionId"] as? String, "s1")
        XCTAssertEqual(r["toolName"] as? String, "Bash")
        XCTAssertEqual(r["toolUseId"] as? String, "toolu_1")
        XCTAssertEqual(r["summary"] as? String, "Build: swift build")
        XCTAssertEqual(r["hook"] as? Bool, true)
        XCTAssertEqual(r["wait"] as? Int, 120)
    }

    func testNoAppMeansNoDecision() {
        let stdin = Data(#"{"hook_event_name":"PermissionRequest","session_id":"s","tool_name":"Bash","tool_input":{}}"#.utf8)
        XCTAssertNil(PromptHook.run(stdin: stdin, socketPath: dir.appendingPathComponent("none.sock").path, wait: 1, env: [:]))
        XCTAssertNil(PromptHook.run(stdin: Data("garbage".utf8), socketPath: "/nonexistent", wait: 1, env: [:]))
    }

    // MARK: settings.json

    func testCommandQuotesPaths() {
        XCTAssertEqual(cmd, "'/Applications/Session Watch.app/Contents/MacOS/claude-watch' prompt-hook --socket "
                       + "'/Users/me/Library/Application Support/claude-watch/bridge.sock'")
        XCTAssertEqual(PromptHookInstaller.quote("it's"), #"'it'\''s'"#)
    }

    func testInstallIntoMissingFile() throws {
        XCTAssertFalse(PromptHookInstaller.isInstalled(settings: settings))
        try PromptHookInstaller.install(settings: settings, command: cmd)
        XCTAssertTrue(PromptHookInstaller.isInstalled(settings: settings))
        let groups = try XCTUnwrap((try read()["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0]["matcher"] as? String, "*")
        let h = try XCTUnwrap((groups[0]["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(h["type"] as? String, "command")
        XCTAssertEqual(h["command"] as? String, cmd)
        XCTAssertEqual(h["timeout"] as? Int, PromptHook.settingsTimeout)
        XCTAssertTrue(backups().isEmpty, "nothing to back up")

        try PromptHookInstaller.remove(settings: settings)
        XCTAssertFalse(PromptHookInstaller.isInstalled(settings: settings))
        XCTAssertNil(try read()["hooks"], "empty hooks object removed")
    }

    func testInstallKeepsEverythingElseAndIsIdempotent() throws {
        let original = """
        {
          "model": "opus",
          "permissions": {"allow": ["Bash(ls:*)"], "deny": []},
          "includeCoAuthoredBy": false,
          "hooks": {
            "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo pre"}]}],
            "PermissionRequest": [
              {"matcher": "Bash", "hooks": [{"type": "command", "command": "~/bin/my-approver", "timeout": 5}]}
            ]
          },
          "statusLine": {"type": "command", "command": "~/.claude/statusline.sh"}
        }
        """
        try original.write(to: settings, atomically: true, encoding: .utf8)
        chmod(settings.path, 0o600)
        let now = Date(timeIntervalSince1970: 1_791_500_000)
        try PromptHookInstaller.install(settings: settings, command: cmd, now: now)
        try PromptHookInstaller.install(settings: settings, command: cmd, now: now.addingTimeInterval(1))

        let obj = try read()
        XCTAssertEqual(obj["model"] as? String, "opus")
        XCTAssertEqual(obj["includeCoAuthoredBy"] as? Bool, false)
        XCTAssertEqual((obj["permissions"] as? [String: Any])?["allow"] as? [String], ["Bash(ls:*)"])
        XCTAssertEqual((obj["statusLine"] as? [String: Any])?["command"] as? String, "~/.claude/statusline.sh")
        let hooks = try XCTUnwrap(obj["hooks"] as? [String: Any])
        XCTAssertEqual((hooks["PreToolUse"] as? [Any])?.count, 1)
        let groups = try XCTUnwrap(hooks["PermissionRequest"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 2, "the user's own hook plus exactly one of ours")
        XCTAssertEqual(((groups[0]["hooks"] as? [[String: Any]])?.first)?["command"] as? String, "~/bin/my-approver")
        let perms = (try FileManager.default.attributesOfItem(atPath: settings.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o600, "permissions kept")

        // Backed up before each change; the first backup is the untouched original.
        let b = backups()
        XCTAssertEqual(b.count, 2)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(b[0]), encoding: .utf8), original)

        try PromptHookInstaller.remove(settings: settings)
        let after = try read()
        let afterGroups = try XCTUnwrap((after["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]])
        XCTAssertEqual(afterGroups.count, 1)
        XCTAssertEqual(((afterGroups[0]["hooks"] as? [[String: Any]])?.first)?["command"] as? String, "~/bin/my-approver")
        XCTAssertEqual(after["model"] as? String, "opus")

        // Removing again changes nothing (and writes no backup).
        let count = backups().count
        try PromptHookInstaller.remove(settings: settings)
        XCTAssertEqual(backups().count, count)
    }

    func testRemoveOnlyOurHookFromASharedGroup() throws {
        let shared: [String: Any] = ["hooks": ["PermissionRequest": [
            ["matcher": "*", "hooks": [["type": "command", "command": "notify-me"], ["type": "command", "command": cmd]]],
        ]]]
        try JSONSerialization.data(withJSONObject: shared).write(to: settings)
        XCTAssertTrue(PromptHookInstaller.isInstalled(settings: settings))
        try PromptHookInstaller.remove(settings: settings)
        let groups = try XCTUnwrap((try read()["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]])
        XCTAssertEqual((groups[0]["hooks"] as? [[String: Any]])?.map { $0["command"] as? String }, ["notify-me"])
    }

    func testRefusesToOverwriteUnreadableSettings() throws {
        try "{ \"model\": \"opus\", // comment\n".write(to: settings, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try PromptHookInstaller.install(settings: settings, command: cmd))
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "{ \"model\": \"opus\", // comment\n")
        try #"{"hooks": []}"#.write(to: settings, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try PromptHookInstaller.install(settings: settings, command: cmd))
        XCTAssertTrue(backups().isEmpty)
    }

    func testSymlinkedSettingsStaysASymlink() throws {
        let real = dir.appendingPathComponent("dotfiles-settings.json")
        try #"{"model": "opus"}"#.write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: real)
        try PromptHookInstaller.install(settings: settings, command: cmd)
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: settings.path))
        XCTAssertTrue(PromptHookInstaller.isInstalled(settings: real))
    }

    func testConfigDirsSharingOneSettingsFileGetOneEntry() throws {
        // ~/.claude/settings.json is real; ~/.claude-1 and ~/.claude-3 link to it (one relative link).
        let fm = FileManager.default
        let main = dir.appendingPathComponent(".claude"), one = dir.appendingPathComponent(".claude-1"),
            three = dir.appendingPathComponent(".claude-3")
        for d in [main, one, three] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        let real = main.appendingPathComponent("settings.json")
        try #"{"model": "opus"}"#.write(to: real, atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: one.appendingPathComponent("settings.json"), withDestinationURL: real)
        try fm.createSymbolicLink(atPath: three.appendingPathComponent("settings.json").path,
                                  withDestinationPath: "../.claude/settings.json")
        let links = [main, one, three].map { $0.appendingPathComponent("settings.json") }

        let files = PromptHookInstaller.files(links)
        XCTAssertEqual(files.map(\.path), [PromptHookInstaller.realFile(real).path])
        for f in files { try PromptHookInstaller.install(settings: f, command: cmd) }
        for l in links { XCTAssertTrue(PromptHookInstaller.isInstalled(settings: l), l.path) }
        for l in links.dropFirst() {
            XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: l.path), "\(l.lastPathComponent) stays a link")
        }
        // Installing through a link edits the shared file in place: still one entry.
        try PromptHookInstaller.install(settings: links[2], command: cmd)
        let groups = try XCTUnwrap((try json(Data(contentsOf: real))["hooks"] as? [String: Any])?["PermissionRequest"] as? [Any])
        XCTAssertEqual(groups.count, 1)
        try PromptHookInstaller.remove(settings: links[1])
        for l in links { XCTAssertFalse(PromptHookInstaller.isInstalled(settings: l)) }
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: links[1].path))
    }

    func testLinkToAMissingFileIsCreatedNotReplaced() throws {
        let fm = FileManager.default
        let target = dir.appendingPathComponent("shared/settings.json")
        try fm.createSymbolicLink(at: settings, withDestinationURL: target)
        try PromptHookInstaller.install(settings: settings, command: cmd)
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: settings.path), "the link wasn't replaced by a file")
        XCTAssertTrue(PromptHookInstaller.isInstalled(settings: target))
    }
}
