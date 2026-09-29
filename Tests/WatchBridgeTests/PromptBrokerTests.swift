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
}
