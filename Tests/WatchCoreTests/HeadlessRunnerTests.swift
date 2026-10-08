import XCTest
@testable import WatchCore

final class HeadlessRunnerTests: XCTestCase {
    var dir: URL!
    var argsFile: URL!
    var stub: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("hr-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        argsFile = dir.appendingPathComponent("args")
        stub = dir.appendingPathComponent("claude")
        try! """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(argsFile.path)'
        printf '%s' "$CLAUDE_CODE_OAUTH_TOKEN" > '\(argsFile.path).token'
        printf '%s' "${CLAUDE_CODE_OAUTH_TOKEN+set}" > '\(argsFile.path).tokenset'
        printf '%s' "$CLAUDE_WATCH_HEADLESS" > '\(argsFile.path).headless'
        exec sleep 30
        """.write(to: stub, atomically: true, encoding: .utf8)
        chmod(stub.path, 0o755)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func session(_ mode: String? = "default") -> SessionInfo {
        SessionInfo(id: "local_1", cliSessionId: "cli-1", priorCliSessionIds: [], profileId: "p", accountUuid: "a/o",
                    title: "Chat", cwd: dir.path, model: nil, permissionMode: mode, lastActivityAt: Date(),
                    isArchived: false, desktopError: nil, desktopErrorAt: nil, hasPendingPermission: false)
    }
    let profile = Profile(id: "p", name: "Work", dataDir: URL(fileURLWithPath: "/tmp"))

    func runner(token: String? = "tok") -> HeadlessRunner {
        HeadlessRunner(binary: { [stub] _ in stub!.path }, token: { _ in token },
                       promptTool: { ["/usr/local/bin/claude-watch", "prompt-tool", "--session", $0] })
    }

    func waitForFile(_ url: URL) {
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: url.path) { usleep(20_000) }
        usleep(50_000)
    }

    func testRunsResumeWithPromptToolAndToken() throws {
        let r = runner()
        guard case .success = r.reply("continue please", session: session(), profile: profile, activity: .idle) else {
            return XCTFail("should start")
        }
        waitForFile(argsFile)
        let args = try String(contentsOf: argsFile, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(Array(args.prefix(4)), ["--resume", "cli-1", "-p", "continue please"])
        XCTAssertTrue(args.contains("--permission-prompt-tool"))
        XCTAssertTrue(args.contains(HeadlessRunner.promptToolName))
        XCTAssertTrue(args.contains { $0.contains("\"prompt-tool\"") && $0.contains("local_1") }, "mcp config names the session")
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: argsFile.path + ".token"), encoding: .utf8), "tok")
        XCTAssertTrue(r.isRunning(sessionId: "local_1"))

        // A second reply while the first runs is refused.
        guard case .failure(let e) = r.reply("again", session: session(), profile: profile, activity: .idle) else {
            return XCTFail("should be busy")
        }
        XCTAssertEqual(e.message, HeadlessRunner.busyMessage)

        let exited = expectation(description: "exit")
        r.onExit = { id, _ in XCTAssertEqual(id, "local_1"); exited.fulfill() }
        XCTAssertTrue(r.stop(sessionId: "local_1"))
        wait(for: [exited], timeout: 8)
        XCTAssertFalse(r.isRunning(sessionId: "local_1"))
        XCTAssertFalse(r.stop(sessionId: "local_1"))
    }

    func testRefusesWorkingChatAndMissingToken() {
        guard case .failure(let busy) = runner().reply("x", session: session(), profile: profile, activity: .working) else {
            return XCTFail("busy")
        }
        XCTAssertEqual(busy.message, HeadlessRunner.busyMessage)
        guard case .failure(let noTok) = runner(token: nil).reply("x", session: session(), profile: profile, activity: .idle) else {
            return XCTFail("no token")
        }
        XCTAssertTrue(noTok.blocked)
        XCTAssertTrue(noTok.message.contains("set-token p"))
    }

    func terminalSession(open: Bool) -> SessionInfo {
        var s = SessionInfo(id: "6f1c2c1e-0000-4000-8000-000000000001", cliSessionId: "6f1c2c1e-0000-4000-8000-000000000001",
                            priorCliSessionIds: [], profileId: Profile.terminalId, accountUuid: "a/o", title: "Term",
                            cwd: dir.path, model: nil, permissionMode: nil, lastActivityAt: Date(), isArchived: false,
                            desktopError: nil, desktopErrorAt: nil, hasPendingPermission: false)
        s.isTerminal = true
        s.openInTerminal = open ? true : nil
        return s
    }

    func testTerminalChatRunsWithTheCLIsOwnLogin() throws {
        // Even with a desktop token around, a terminal chat runs as whoever `claude` is signed into.
        let r = runner(token: "desktop-token")
        let s = terminalSession(open: false)
        guard case .success = r.reply("go on", session: s, profile: .terminal, activity: .idle) else {
            return XCTFail("should start without a token")
        }
        waitForFile(URL(fileURLWithPath: argsFile.path + ".headless"))
        let args = try String(contentsOf: argsFile, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(Array(args.prefix(2)), ["--resume", s.id])
        XCTAssertTrue(args.contains("--permission-prompt-tool"), "phone still answers its prompts")
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: argsFile.path + ".tokenset"), encoding: .utf8), "",
                       "CLAUDE_CODE_OAUTH_TOKEN is left unset")
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: argsFile.path + ".headless"), encoding: .utf8), "1")
        r.stop(sessionId: s.id)
    }

    func testTerminalChatOpenInATerminalIsRefused() {
        let s = terminalSession(open: true)
        XCTAssertEqual(HeadlessRunner.terminalGuard(s)?.message, HeadlessRunner.openInTerminalMessage)
        XCTAssertNil(HeadlessRunner.terminalGuard(terminalSession(open: false)))
        XCTAssertNil(HeadlessRunner.terminalGuard(session()), "desktop chats aren't affected")
        guard case .failure(let e) = runner().reply("x", session: s, profile: .terminal, activity: .idle) else {
            return XCTFail("should refuse")
        }
        XCTAssertTrue(e.message.contains("open in a terminal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: argsFile.path), "nothing ran")
    }

    func testBypassModeSkipsPromptTool() {
        let args = HeadlessRunner.arguments(cli: "c", text: "t", permissionMode: "bypassPermissions", promptTool: ["x"])
        XCTAssertFalse(args.contains("--permission-prompt-tool"))
    }

    func testPromptToolProtocol() throws {
        let ask: PromptTool.Ask = { tool, input, _ in
            tool == "Bash" && input["command"] as? String == "ls" ? .init(allow: true, message: nil) : .init(allow: false, message: "no")
        }
        let initR = try XCTUnwrap(PromptTool.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                                     "params": ["protocolVersion": "2025-06-18"]], ask: ask))
        XCTAssertEqual((initR["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNil(PromptTool.handle(["jsonrpc": "2.0", "method": "notifications/initialized"], ask: ask))
        let list = try XCTUnwrap(PromptTool.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"], ask: ask))
        XCTAssertEqual(((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.first?["name"] as? String, "approve")

        func call(_ input: [String: Any]) throws -> [String: Any] {
            let r = try XCTUnwrap(PromptTool.handle(["jsonrpc": "2.0", "id": 3, "method": "tools/call",
                                                     "params": ["name": "approve",
                                                                "arguments": ["tool_name": "Bash", "input": input]]], ask: ask))
            let text = (((r["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }
        let allow = try call(["command": "ls"])
        XCTAssertEqual(allow["behavior"] as? String, "allow")
        XCTAssertEqual((allow["updatedInput"] as? [String: Any])?["command"] as? String, "ls")
        let deny = try call(["command": "rm -rf /"])
        XCTAssertEqual(deny["behavior"] as? String, "deny")
        XCTAssertEqual(deny["message"] as? String, "no")
    }
}
