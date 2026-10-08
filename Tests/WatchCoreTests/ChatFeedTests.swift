import XCTest
@testable import WatchCore

final class ChatFeedTests: XCTestCase {
    func fixtureLines() -> [Data] {
        let url = Bundle.module.url(forResource: "chat", withExtension: "jsonl", subdirectory: "Fixtures")!
        return try! Data(contentsOf: url).split(separator: 0x0A).map { Data($0) }
    }

    func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("chatfeed-\(UUID().uuidString).jsonl")
    }

    func testMessagesFromFixture() {
        let m = ChatFeed.messages(fromLines: fixtureLines())
        XCTAssertEqual(m.map(\.kind), [.user, .assistant, .tool, .tool, .error, .user, .assistant])
        XCTAssertEqual(m[0].text, "add a **retry** button")
        XCTAssertEqual(m[1].text, "I'll build it first.")
        XCTAssertEqual(m[2].text, "Ran swift build")
        XCTAssertEqual(m[2].toolName, "Bash")
        XCTAssertEqual(m[2].toolOK, true)
        XCTAssertEqual(m[3].text, "Edited App.swift")
        XCTAssertEqual(m[3].toolOK, false)
        XCTAssertEqual(m[4].text, "You've hit your limit · resets 4:50am")
        XCTAssertEqual(m[5].text, "continue")
        XCTAssertEqual(Set(m.map(\.id)).count, m.count, "ids are unique")
    }

    func testOneLiners() {
        XCTAssertEqual(ChatFeed.oneLiner(tool: "Read", input: ["file_path": "/a/b/Readers.swift"]), "Read Readers.swift")
        XCTAssertEqual(ChatFeed.oneLiner(tool: "Write", input: ["file_path": "/a/New.swift"]), "Wrote New.swift")
        XCTAssertEqual(ChatFeed.oneLiner(tool: "Grep", input: ["pattern": "TODO"]), "Searched “TODO”")
        XCTAssertEqual(ChatFeed.oneLiner(tool: "Agent", input: ["description": "Survey code"]), "Agent: Survey code")
        XCTAssertEqual(ChatFeed.oneLiner(tool: "mcp__github__create_issue", input: [:]), "github · create issue")
        XCTAssertEqual(ChatFeed.oneLiner(tool: "WebFetch", input: ["url": "https://docs.swift.org/x"]), "Fetched docs.swift.org")
        let long = String(repeating: "a", count: 200)
        XCTAssertEqual(ChatFeed.oneLiner(tool: "Bash", input: ["command": long]).count, "Ran ".count + 80 + 1)
    }

    func testIncrementalPollHoldsPartialLineAndUpdatesTools() throws {
        let lines = fixtureLines()
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        // Everything up to and including the Bash tool_use, plus half of its tool_result line.
        var data = Data(lines[0..<5].joined(separator: Data([0x0A])))
        data.append(0x0A)
        let result = lines[5]
        data.append(result.prefix(20))
        try data.write(to: url)

        let feed = ChatFeed(url: url)
        let first = feed.poll()
        XCTAssertEqual(first.map(\.kind), [.user, .assistant, .tool])
        XCTAssertNil(first[2].toolOK, "result not complete yet")

        let h = try FileHandle(forWritingTo: url)
        h.seekToEndOfFile()
        h.write(result.dropFirst(20))
        h.write(Data([0x0A]))
        try h.close()
        let second = feed.poll()
        XCTAssertEqual(second.count, 1, "only the updated tool message")
        XCTAssertEqual(second[0].id, first[2].id)
        XCTAssertEqual(second[0].toolOK, true)
        XCTAssertTrue(feed.poll().isEmpty)
    }

    func testPaging() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(fixtureLines().joined(separator: Data([0x0A]))).write(to: url)
        let last = ChatFeed.page(url: url, before: nil, limit: 3)
        XCTAssertEqual(last.messages.map(\.text), ["You've hit your limit · resets 4:50am", "continue", "Done — the button is in."])
        XCTAssertEqual(last.before, 4)
        let earlier = ChatFeed.page(url: url, before: 4, limit: 3)
        XCTAssertEqual(earlier.messages.map(\.kind), [.assistant, .tool, .tool])
        XCTAssertEqual(earlier.before, 1)
        let first = ChatFeed.page(url: url, before: 1, limit: 3)
        XCTAssertEqual(first.messages.count, 1)
        XCTAssertNil(first.before)
    }

    func testTranscriptCacheMatchesAFreshParseAndCarriesOn() throws {
        let lines = fixtureLines()
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        var data = Data(lines[0..<5].joined(separator: Data([0x0A])))
        data.append(0x0A)
        try data.write(to: url)

        let cache = TranscriptCache()
        let (first, feed) = cache.open(url)
        XCTAssertEqual(first, ChatFeed.messages(fromLines: Array(lines[0..<5])))
        XCTAssertTrue(feed.poll().isEmpty, "the feed starts where the cache left off")

        let h = try FileHandle(forWritingTo: url)
        h.seekToEndOfFile()
        h.write(Data(lines[5...].joined(separator: Data([0x0A]))))
        h.write(Data([0x0A]))
        try h.close()
        XCTAssertFalse(feed.poll().isEmpty)
        let all = ChatFeed.messages(fromLines: lines)
        XCTAssertEqual(cache.open(url).messages, all)
        XCTAssertEqual(cache.page(url, before: nil, limit: 3).messages, Array(all.suffix(3)))
    }
}
