import XCTest
@testable import WatchCore

final class WorkTrackerTests: XCTestCase {
    let t0 = TranscriptScanner.parseISO("2026-10-08T10:00:00.000Z")!

    func fixture(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/work")!
    }

    func lines(_ name: String) -> [Data] {
        try! Data(contentsOf: fixture(name)).split(separator: 0x0A).map { Data($0) }
    }

    /// A temp copy of the fixture chat (main transcript + subagents folder), as Claude Code lays it out.
    func tempChat() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("work-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture("s1.jsonl"), to: dir.appendingPathComponent("s1.jsonl"))
        try FileManager.default.copyItem(at: fixture("s1.jsonl").deletingPathExtension(), to: dir.appendingPathComponent("s1"))
        return dir.appendingPathComponent("s1.jsonl")
    }

    func append(_ lines: [Data], to url: URL) throws {
        let h = try FileHandle(forWritingTo: url)
        h.seekToEndOfFile()
        for l in lines { h.write(l); h.write(Data([0x0A])) }
        try h.close()
    }

    func testRunningToolsAgentsAndShells() throws {
        let url = try tempChat()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let feed = ChatFeed(url: url)
        _ = feed.poll()
        let w = feed.workTracker.live(now: t0.addingTimeInterval(30))

        XCTAssertEqual(w.running.map(\.summary), ["Bash: swift test"], "finished Bash and Monitor calls are gone")
        XCTAssertEqual(w.running.first?.startedAt, t0.addingTimeInterval(11))

        XCTAssertEqual(w.agents.map(\.id), ["ta1", "ta2"])
        let survey = w.agents[0], docs = w.agents[1]
        XCTAssertEqual(survey.description, "Survey the parser")
        XCTAssertEqual(survey.type, "Explore")
        XCTAssertEqual(survey.status, .running)
        XCTAssertFalse(survey.background)
        XCTAssertEqual(survey.steps, 2, "from its subagent transcript, linked by meta.json")
        XCTAssertEqual(survey.step, "Searched “consume”")
        XCTAssertTrue(docs.background, "async_launched")
        XCTAssertEqual(docs.status, .running)
        XCTAssertEqual(docs.steps, 1, "linked by the agentId in its launch result")
        XCTAssertEqual(docs.step, "Edited README.md")

        XCTAssertEqual(w.shells.map(\.id), ["bg1", "mon1"])
        XCTAssertEqual(w.shells.map(\.summary), ["Start the dev server", "watch the log"])
        XCTAssertEqual(w.shells.map(\.kind), [.shell, .monitor])
        XCTAssertTrue(w.shells.allSatisfy { $0.status == .running })
        XCTAssertEqual(w.line, "2 agents · 2 shells · Bash: swift test")

        // Subagents keep working: only the appended step is read.
        try append([Data(#"{"isSidechain":true,"agentId":"a1a","type":"assistant","message":{"id":"sm3","content":[{"type":"tool_use","id":"st3","name":"Bash","input":{"command":"swift test"}}]},"uuid":"s5","timestamp":"2026-10-08T10:00:12.000Z"}"#.utf8)],
                   to: url.deletingPathExtension().appendingPathComponent("subagents/agent-a1a.jsonl"))
        XCTAssertTrue(feed.poll().isEmpty, "no new chat messages")
        let w2 = feed.workTracker.live(now: t0.addingTimeInterval(31))
        XCTAssertEqual(w2.agents[0].steps, 3)
        XCTAssertEqual(w2.agents[0].step, "Ran swift test")
    }

    func testResultsAndNotificationsEndWork() throws {
        let url = try tempChat()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let feed = ChatFeed(url: url)
        _ = feed.poll()
        try append(lines("s1-more.jsonl"), to: url)
        let new = feed.poll()
        XCTAssertFalse(new.contains { $0.kind == .user }, "task notifications aren't shown as your messages")

        let w = feed.workTracker.live(now: t0.addingTimeInterval(200))
        XCTAssertTrue(w.running.isEmpty)
        XCTAssertEqual(w.agents.map(\.status), [.done, .done])
        XCTAssertEqual(w.agents.map(\.steps), [5, 3], "totalToolUseCount / <tool_uses>")
        XCTAssertEqual(w.agents[1].endedAt, t0.addingTimeInterval(120))
        XCTAssertEqual(w.shells.first { $0.id == "bg1" }?.status, .stopped)
        XCTAssertEqual(w.shells.first { $0.id == "mon1" }?.status, .running, "monitor events don't end it")
        XCTAssertFalse(w.isEmpty, "this turn's finished items stay for the open chat")
        XCTAssertEqual(w.brief?.shells.map(\.id), ["mon1"], "the snapshot form keeps running items only")
        XCTAssertNil(w.brief?.agents.first)

        // The monitor times out after 10 minutes.
        XCTAssertNil(feed.workTracker.live(now: t0.addingTimeInterval(11 * 60)).brief)

        // A new prompt clears the last turn.
        try append([Data(#"{"type":"user","uuid":"u2","isSidechain":false,"message":{"role":"user","content":"thanks"},"timestamp":"2026-10-08T10:03:00.000Z"}"#.utf8)], to: url)
        _ = feed.poll()
        let after = feed.workTracker.live(now: t0.addingTimeInterval(200))
        XCTAssertTrue(after.agents.isEmpty)
        XCTAssertEqual(after.shells.map(\.id), ["mon1"])
    }

    func testInterruptStopsForegroundWork() {
        var t = WorkTracker()
        for l in lines("s1.jsonl") { t.consume(try! JSONSerialization.jsonObject(with: l) as! [String: Any]) }
        t.consume(["type": "user", "timestamp": "2026-10-08T10:00:40.000Z",
                   "message": ["role": "user", "content": [["type": "text", "text": "[Request interrupted by user for tool use]"]]]])
        let w = t.live(now: t0.addingTimeInterval(60))
        XCTAssertTrue(w.running.isEmpty)
        XCTAssertEqual(w.agents.map(\.status), [.stopped, .running], "the background agent carries on")
    }

    func testOrphansAreHidden() {
        var t = WorkTracker()
        for l in lines("s1.jsonl") { t.consume(try! JSONSerialization.jsonObject(with: l) as! [String: Any]) }
        let w = t.live(now: t0.addingTimeInterval(13 * 3600))
        XCTAssertTrue(w.running.isEmpty && w.activeAgents.isEmpty && w.activeShells.isEmpty)
    }

    func testTaskStopEndsShell() {
        var t = WorkTracker()
        for l in lines("s1.jsonl") { t.consume(try! JSONSerialization.jsonObject(with: l) as! [String: Any]) }
        t.consume(["type": "assistant", "timestamp": "2026-10-08T10:00:50.000Z",
                   "message": ["content": [["type": "tool_use", "id": "ts1", "name": "TaskStop", "input": ["task_id": "bg1"]]]]])
        t.consume(["type": "user", "timestamp": "2026-10-08T10:00:51.000Z",
                   "message": ["content": [["type": "tool_result", "tool_use_id": "ts1", "content": "stopped"]]],
                   "toolUseResult": ["task_id": "bg1", "task_type": "local_bash"]])
        XCTAssertEqual(t.live(now: t0.addingTimeInterval(60)).shells.first { $0.id == "bg1" }?.status, .stopped)
    }

    func testScannerKeepsBriefWork() {
        let scanner = TranscriptScanner(cacheURL: URL(fileURLWithPath: "/dev/null"), projectsDir: URL(fileURLWithPath: "/nonexistent"))
        var st = FileScanState()
        var b = TokenBuckets()
        for l in lines("s1.jsonl") { scanner.processLine(l, state: &st, buckets: &b, horizon: .distantPast) }
        let brief = st.work?.live(now: t0.addingTimeInterval(30)).brief
        XCTAssertEqual(brief?.line, "2 agents · 2 shells · Bash: swift test")
        XCTAssertEqual(brief?.agents.map(\.steps), [0, 0])

        // Kept in the scan cache across launches.
        let data = try! JSONEncoder().encode(st)
        let back = try! JSONDecoder().decode(FileScanState.self, from: data)
        XCTAssertEqual(back.work?.live(now: t0.addingTimeInterval(30)), st.work?.live(now: t0.addingTimeInterval(30)))
    }

    func testTags() {
        XCTAssertEqual(WorkTracker.tags("task-id", in: "<task-id>a</task-id>\n<task-id> b </task-id>"), ["a", "b"])
        XCTAssertEqual(WorkTracker.label(tool: "Bash", input: ["command": "swift test\nmore"]), "Bash: swift test")
        XCTAssertEqual(WorkTracker.label(tool: "Read", input: ["file_path": "/a/App.swift"]), "Read App.swift")
    }

    /// Notifications that arrive mid-turn are written as `queued_command` attachments, and task
    /// status changes as `task_status` attachments, not as user entries.
    func testMidTurnNotificationsEndAgentsAndShells() throws {
        func j(_ o: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: o) }
        let ts = "2026-10-08T10:00:01.000Z"
        let lines: [Data] = [
            j(["type": "assistant", "timestamp": ts, "message": ["content": [
                ["type": "tool_use", "id": "tu_a", "name": "Agent", "input": ["description": "Build it", "prompt": "x", "run_in_background": true]],
                ["type": "tool_use", "id": "tu_b", "name": "Bash", "input": ["command": "make", "description": "Make", "run_in_background": true]],
            ]]]),
            j(["type": "user", "timestamp": ts, "message": ["content": [["type": "tool_result", "tool_use_id": "tu_a", "content": "launched"]]],
               "toolUseResult": ["isAsync": true, "status": "async_launched", "agentId": "ag1"]]),
            j(["type": "user", "timestamp": ts, "message": ["content": [["type": "tool_result", "tool_use_id": "tu_b", "content": "bg"]]],
               "toolUseResult": ["backgroundTaskId": "sh1"]]),
        ]
        var feed = ChatParser()
        for l in lines { _ = feed.consume(l) }
        var w = feed.work.live(now: t0.addingTimeInterval(5))
        XCTAssertEqual(w.agents.filter { $0.status == .running }.count, 1)
        XCTAssertEqual(w.shells.filter { $0.status == .running }.count, 1)

        let queued = j(["isSidechain": false, "attachment": ["type": "queued_command",
            "prompt": "<task-notification>\n<task-id>ag1</task-id>\n<tool-use-id>tu_a</tool-use-id>\n<status>completed</status>\n</task-notification>"],
            "type": "attachment", "timestamp": ts])
        let status = j(["isSidechain": false, "attachment": ["type": "task_status", "taskId": "sh1", "status": "failed"],
            "type": "attachment", "timestamp": ts])
        _ = feed.consume(queued)
        _ = feed.consume(status)
        w = feed.work.live(now: t0.addingTimeInterval(6))
        XCTAssertTrue(w.agents.allSatisfy { $0.status == .done })
        XCTAssertEqual(w.shells.map(\.status), [.failed])
    }
}
