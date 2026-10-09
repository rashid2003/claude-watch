import XCTest
@testable import WatchBridge
import WatchProtocol

final class ReplyQueueTests: XCTestCase {
    func testTakeReturnsAChatsRepliesInOrderAndLeavesOthers() {
        let q = ReplyQueue(url: nil)
        q.add(chatId: "a", text: "one")
        q.add(chatId: "b", text: "other")
        q.add(chatId: "a", text: "two")
        XCTAssertEqual(q.waitingChats, ["a", "b"])
        let batch = q.take(chatId: "a")
        XCTAssertEqual(batch.map(\.text), ["one", "two"])
        XCTAssertEqual(ReplyQueue.combined(batch), "one\n\ntwo")
        XCTAssertEqual(q.all.map(\.chatId), ["b"])
    }

    func testFailedRepliesStayButAreNotSentAgain() {
        let q = ReplyQueue(url: nil)
        q.add(chatId: "a", text: "hi")
        q.fail(q.take(chatId: "a"), error: "window closed")
        XCTAssertEqual(q.all.first?.error, "window closed")
        XCTAssertFalse(q.has(chatId: "a"))
        XCTAssertTrue(q.waitingChats.isEmpty)
        XCTAssertTrue(q.take(chatId: "a").isEmpty)
    }

    func testRemoveAndPersistence() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rq-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let q = ReplyQueue(url: url)
        let r = q.add(chatId: "a", text: "keep")
        let gone = q.add(chatId: "a", text: "drop")
        XCTAssertTrue(q.remove(id: gone.id))
        XCTAssertFalse(q.remove(id: gone.id))
        // Compare ids: a Date doesn't survive the seconds-since-1970 round trip to the last bit.
        XCTAssertEqual(ReplyQueue(url: url).all.map(\.id), [r.id])
    }
}

extension ReplyQueueTests {
    func testRetryClearsErrorAndRequeues() {
        let q = ReplyQueue(url: nil)
        let r = q.add(chatId: "c", text: "x")
        let taken = q.take(chatId: "c")
        q.fail(taken, error: "boom")
        XCTAssertFalse(q.has(chatId: "c"))
        q.retry(id: r.id)
        XCTAssertTrue(q.has(chatId: "c"))
    }
}
