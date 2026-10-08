import XCTest
@testable import WatchBridge
import WatchCore

final class PromptBrokerTests: XCTestCase {
    func testRoundTripThroughTheSocket() throws {
        // sun_path is short: keep the socket path small.
        let path = "/tmp/cwpb-\(UUID().uuidString.prefix(6)).sock"
        let broker = PromptBroker(path: path)
        broker.describe = { id in id == "local_1" ? ("Fix bug", "account-1") : nil }
        let appeared = expectation(description: "prompt appears")
        broker.onChange = { list in if !list.isEmpty { appeared.fulfill() } }
        try broker.start()
        defer { broker.stop() }

        var answer: PromptTool.Answer?
        let done = expectation(description: "tool got an answer")
        DispatchQueue.global().async {
            answer = PromptTool.ask(socketPath: path, sessionId: "local_1", tool: "Bash",
                                    input: ["command": "swift build"], toolUseId: "t1")
            done.fulfill()
        }
        wait(for: [appeared], timeout: 3)
        let p = try XCTUnwrap(broker.prompts.first)
        XCTAssertEqual(p.chatTitle, "Fix bug")
        XCTAssertEqual(p.profileId, "account-1")
        XCTAssertEqual(p.source, .headless)
        XCTAssertEqual(p.summary, "swift build")
        broker.onChange = nil
        XCTAssertTrue(broker.answer(id: p.id, allow: true))
        wait(for: [done], timeout: 3)
        XCTAssertEqual(answer, PromptTool.Answer(allow: true, message: nil))
        XCTAssertTrue(broker.prompts.isEmpty)
        XCTAssertFalse(broker.answer(id: p.id, allow: false), "already answered")
    }

    func testNoBrokerMeansDeny() {
        let a = PromptTool.ask(socketPath: "/tmp/nothing-here-\(UUID().uuidString.prefix(4)).sock", sessionId: "s",
                               tool: "Bash", input: [:], toolUseId: nil)
        XCTAssertFalse(a.allow)
    }

    // MARK: Terminal prompt hook

    let hookInput = Data(#"{"hook_event_name":"PermissionRequest","session_id":"term-1","tool_name":"Bash","tool_input":{"command":"make"}}"#.utf8)

    func startBroker(hold: Bool) throws -> (PromptBroker, String) {
        let path = "/tmp/cwpb-\(UUID().uuidString.prefix(6)).sock"
        let broker = PromptBroker(path: path)
        broker.describe = { _ in ("Terminal chat", "terminal") }
        broker.holdHook = { _ in hold }
        try broker.start()
        return (broker, path)
    }

    func testHookDefersAtOnceWithoutAPhone() throws {
        let (broker, path) = try startBroker(hold: false)
        defer { broker.stop() }
        let start = Date()
        XCTAssertNil(PromptHook.run(stdin: hookInput, socketPath: path, wait: 60, env: [:]))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertTrue(broker.prompts.isEmpty)
    }

    func testHookGetsThePhonesAnswer() throws {
        let (broker, path) = try startBroker(hold: true)
        defer { broker.stop() }
        let appeared = expectation(description: "prompt appears")
        broker.onChange = { list in if !list.isEmpty { appeared.fulfill() } }
        var out: Data?
        let done = expectation(description: "hook returned")
        DispatchQueue.global().async {
            out = PromptHook.run(stdin: self.hookInput, socketPath: path, wait: 60, env: [:])
            done.fulfill()
        }
        wait(for: [appeared], timeout: 3)
        broker.onChange = nil
        let p = try XCTUnwrap(broker.prompts.first)
        XCTAssertTrue(PromptBroker.isHook(p.id))
        XCTAssertEqual(p.chatId, "term-1")
        XCTAssertEqual(p.source, .headless)
        XCTAssertEqual(p.summary, "make")
        XCTAssertTrue(broker.answer(id: p.id, allow: false, message: "nope"))
        wait(for: [done], timeout: 3)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(out)) as? [String: Any])
        let d = (obj["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        XCTAssertEqual(d?["behavior"] as? String, "deny")
        XCTAssertEqual(d?["message"] as? String, "nope")
    }

    func testHookTimesOutToNoDecision() throws {
        let (broker, path) = try startBroker(hold: true)
        defer { broker.stop() }
        let start = Date()
        XCTAssertNil(PromptHook.run(stdin: hookInput, socketPath: path, wait: 1, env: [:]))
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        XCTAssertTrue(broker.prompts.isEmpty)
    }

    func testReleasedHookPromptFallsThrough() throws {
        let (broker, path) = try startBroker(hold: true)
        defer { broker.stop() }
        let appeared = expectation(description: "prompt appears")
        broker.onChange = { list in if !list.isEmpty { appeared.fulfill() } }
        var out: Data? = Data("unset".utf8)
        let done = expectation(description: "hook returned")
        DispatchQueue.global().async {
            out = PromptHook.run(stdin: self.hookInput, socketPath: path, wait: 60, env: [:])
            done.fulfill()
        }
        wait(for: [appeared], timeout: 3)
        broker.onChange = nil
        XCTAssertTrue(broker.release(id: try XCTUnwrap(broker.prompts.first).id))
        wait(for: [done], timeout: 3)
        XCTAssertNil(out, "answered in the terminal: no decision")
    }

    func testAskerHangingUpDropsThePrompt() throws {
        let (broker, path) = try startBroker(hold: true)
        defer { broker.stop() }
        let appeared = expectation(description: "prompt appears")
        let gone = expectation(description: "prompt dropped")
        gone.assertForOverFulfill = false
        appeared.assertForOverFulfill = false
        broker.onChange = { list in if list.isEmpty { gone.fulfill() } else { appeared.fulfill() } }
        let body = try JSONSerialization.data(withJSONObject: ["sessionId": "term-1", "hook": true, "wait": 60])
        // A raw client that sends its request and then closes the connection.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in Array(path.utf8).enumerated() { buf[i] = b }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(ok, 0)
        let line = body + Data([0x0A])
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, line.count) }
        wait(for: [appeared], timeout: 3)
        close(fd)
        wait(for: [gone], timeout: 3)
        XCTAssertTrue(broker.prompts.isEmpty)
    }
}
