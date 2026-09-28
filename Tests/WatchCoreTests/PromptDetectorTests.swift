import XCTest
@testable import WatchCore

final class PromptDetectorTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_790_600_000)

    func tool(_ name: String, _ fields: [String: String] = [:]) -> OpenToolUse {
        OpenToolUse(id: "t1", name: name, fields: fields, at: t0)
    }

    func testBashWithoutChildIsWaiting() {
        let t = tool("Bash", ["command": "rm -rf build"])
        XCTAssertFalse(PromptDetector.isWaiting(t, transcriptMtime: t0, childStarts: [], now: t0.addingTimeInterval(2)))
        XCTAssertTrue(PromptDetector.isWaiting(t, transcriptMtime: t0, childStarts: [], now: t0.addingTimeInterval(6)))
    }

    func testBashWithFreshChildIsRunning() {
        let t = tool("Bash")
        XCTAssertFalse(PromptDetector.isWaiting(t, transcriptMtime: t0, childStarts: [t0.addingTimeInterval(0.5)],
                                                now: t0.addingTimeInterval(60)))
        // A long-lived child from before the tool call (an MCP server) doesn't count.
        XCTAssertTrue(PromptDetector.isWaiting(t, transcriptMtime: t0, childStarts: [t0.addingTimeInterval(-600)],
                                               now: t0.addingTimeInterval(60)))
    }

    func testTranscriptStillMovingIsNotWaiting() {
        XCTAssertFalse(PromptDetector.isWaiting(tool("Edit"), transcriptMtime: t0.addingTimeInterval(58), childStarts: [],
                                                now: t0.addingTimeInterval(60)))
    }

    func testSlowInProcessTools() {
        XCTAssertFalse(PromptDetector.isWaiting(tool("Agent"), transcriptMtime: t0, childStarts: [], now: t0.addingTimeInterval(600)))
        XCTAssertFalse(PromptDetector.isWaiting(tool("WebFetch"), transcriptMtime: t0, childStarts: [], now: t0.addingTimeInterval(10)))
        XCTAssertTrue(PromptDetector.isWaiting(tool("WebFetch"), transcriptMtime: t0, childStarts: [], now: t0.addingTimeInterval(30)))
        XCTAssertFalse(PromptDetector.isWaiting(tool("mcp__x__y"), transcriptMtime: t0, childStarts: [], now: t0.addingTimeInterval(10)))
        XCTAssertTrue(PromptDetector.isWaiting(tool("mcp__x__y"), transcriptMtime: t0, childStarts: [], now: t0.addingTimeInterval(25)))
    }

    func testQuestionsWaitAtOnce() {
        XCTAssertTrue(PromptDetector.isWaiting(tool("AskUserQuestion"), transcriptMtime: t0, childStarts: [],
                                               now: t0.addingTimeInterval(1)))
    }

    func write(_ lines: [String]) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pd-\(UUID().uuidString).jsonl")
        try! (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    let use = #"{"type":"assistant","uuid":"a1","isSidechain":false,"message":{"content":[{"type":"tool_use","id":"t9","name":"Bash","input":{"command":"swift build","description":"Build"}}]},"timestamp":"2026-09-28T20:00:03.000Z"}"#
    let result = #"{"type":"user","uuid":"r1","isSidechain":false,"message":{"content":[{"type":"tool_result","tool_use_id":"t9","content":"ok"}]},"timestamp":"2026-09-28T20:00:09.000Z"}"#
    let prompt = #"{"type":"user","uuid":"u1","isSidechain":false,"message":{"content":"go"},"timestamp":"2026-09-28T20:00:00.000Z"}"#

    func testOpenToolUse() {
        let open = write([prompt, use])
        defer { try? FileManager.default.removeItem(at: open) }
        let t = PromptDetector.openToolUse(url: open)
        XCTAssertEqual(t?.id, "t9")
        XCTAssertEqual(t?.name, "Bash")
        XCTAssertEqual(t?.fields["command"], "swift build")

        let done = write([prompt, use, result])
        defer { try? FileManager.default.removeItem(at: done) }
        XCTAssertNil(PromptDetector.openToolUse(url: done))
    }

    func testQuestionSummary() {
        let q = #"{"type":"assistant","uuid":"a2","isSidechain":false,"message":{"content":[{"type":"tool_use","id":"q1","name":"AskUserQuestion","input":{"questions":[{"question":"Which database?","options":[]}]}}]},"timestamp":"2026-09-28T20:00:03.000Z"}"#
        let url = write([prompt, q])
        defer { try? FileManager.default.removeItem(at: url) }
        let t = PromptDetector.openToolUse(url: url)!
        XCTAssertEqual(t.fields["question"], "Which database?")
        let info = SessionInfo(id: "local_1", cliSessionId: "c", priorCliSessionIds: [], profileId: "p", accountUuid: "a/o",
                               title: "Chat", cwd: "/", model: nil, permissionMode: nil, lastActivityAt: t0,
                               isArchived: false, desktopError: nil, desktopErrorAt: nil, hasPendingPermission: false)
        let p = PromptDetector.prompt(for: info, tool: t)
        XCTAssertEqual(p.kind, .question)
        XCTAssertEqual(p.summary, "Which database?")
        XCTAssertEqual(p.id, "local_1/q1")
    }
}
