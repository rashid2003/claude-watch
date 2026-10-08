import XCTest
@testable import WatchCore
import WatchProtocol

/// Reading transcripts from the end must give exactly the messages a parse from the start gives.
final class TranscriptHistoryTests: XCTestCase {
    var urls: [URL] = []

    override func tearDown() {
        for u in urls { try? FileManager.default.removeItem(at: u) }
        urls = []
    }

    func write(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tail-\(UUID().uuidString).jsonl")
        try data.write(to: url)
        urls.append(url)
        return url
    }

    func append(_ lines: [Data], to url: URL) throws {
        let h = try FileHandle(forWritingTo: url)
        h.seekToEndOfFile()
        for l in lines { h.write(l); h.write(Data([0x0A])) }
        try h.close()
    }

    func json(_ o: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) }

    /// A long, real-looking transcript: prompts, text, tool calls answered later (some never, some twice,
    /// some ids reused), several calls per line, huge results (> 256 KB, past the parser's raw path),
    /// sidechains, meta entries, attachments, API errors.
    func synthetic(entries: Int, seed: UInt64 = 7) -> [Data] {
        var rng = SplitMix(seed: seed)
        var lines: [Data] = []
        var open: [String] = []      // calls waiting for a result
        var used: [String] = []      // every call id so far
        var n = 0
        func ts() -> String {
            n += 1
            return String(format: "2026-10-08T%02d:%02d:%02d.000Z", (n / 3600) % 24, (n / 60) % 60, n % 60)
        }
        func user(_ content: Any, extra: [String: Any] = [:]) {
            var o: [String: Any] = ["type": "user", "uuid": "u\(lines.count)", "isSidechain": false, "timestamp": ts(),
                                    "message": ["role": "user", "content": content]]
            o.merge(extra) { $1 }
            lines.append(json(o))
        }
        func assistant(_ blocks: [[String: Any]], extra: [String: Any] = [:]) {
            var o: [String: Any] = ["type": "assistant", "uuid": "a\(lines.count)", "isSidechain": false, "timestamp": ts(),
                                    "message": ["id": "m\(lines.count)", "content": blocks]]
            o.merge(extra) { $1 }
            lines.append(json(o))
        }
        func call() -> [String: Any] {
            // Now and then an id comes back (Claude Code never does this, but the parser must agree anyway).
            let id = !used.isEmpty && rng.next(100) < 3 ? used[rng.next(used.count)] : "toolu_\(used.count)"
            used.append(id); open.append(id)
            let tools: [(String, [String: Any])] = [("Bash", ["command": "swift test --filter X\(n)"]), ("Read", ["file_path": "/a/F\(n).swift"]),
                                                     ("Edit", ["file_path": "/a/G.swift"]), ("Grep", ["pattern": "foo\(n)"])]
            let (name, input) = tools[rng.next(tools.count)]
            return ["type": "tool_use", "id": id, "name": name, "input": input]
        }
        func result(_ id: String, huge: Bool = false) -> [String: Any] {
            var r: [String: Any] = ["type": "tool_result", "tool_use_id": id,
                                    "content": huge ? String(repeating: "x", count: 262_200 + rng.next(60_000)) : "ok \(n)"]
            if rng.next(5) == 0 { r["is_error"] = true }
            return r
        }
        for _ in 0..<entries {
            switch rng.next(100) {
            case 0..<10: user(rng.next(4) == 0 ? "<system-reminder>skip</system-reminder>" : "please do thing \(n)")
            case 10..<12: user([["type": "text", "text": "<command-name>/review</command-name><command-args>now</command-args>"]])
            case 12..<14: user("meta \(n)", extra: ["isMeta": true])
            case 14..<16: assistant([["type": "text", "text": "side \(n)"]], extra: ["isSidechain": true])
            case 16..<18:
                lines.append(json(["type": "attachment", "uuid": "x\(lines.count)", "timestamp": ts(),
                                   "attachment": ["type": "queued_command", "prompt": "<task-notification>done</task-notification>"]]))
            case 18..<19:
                assistant([["type": "text", "text": "You've hit your limit"]], extra: ["isApiErrorMessage": true, "error": "rate_limit"])
            case 19..<30: assistant([["type": "thinking", "thinking": "hmm"], ["type": "text", "text": "Working on \(n)."]])
            case 30..<55: assistant(rng.next(3) == 0 ? [["type": "text", "text": "Two at once:"], call(), call()] : [call()])
            case 55..<92:
                guard !open.isEmpty else { continue }
                // Answer one or more waiting calls (not always the oldest), sometimes a stale id again.
                var blocks: [[String: Any]] = []
                for _ in 0..<(1 + rng.next(2)) where !open.isEmpty {
                    blocks.append(result(open.remove(at: rng.next(min(open.count, 4)))))
                }
                if rng.next(20) == 0, let old = used.first { blocks.append(result(old)) }
                user(blocks)
            case 92..<95:
                guard !open.isEmpty else { continue }
                user([result(open.removeFirst(), huge: true)])
            default:
                // Calls that are never answered, and plain small lines.
                if rng.next(2) == 0, !open.isEmpty { open.removeLast() } else { assistant([["type": "text", "text": "ok"]]) }
            }
        }
        return lines
    }

    /// Every page from the newest back, oldest first, with the page sizes seen.
    func pageAll(_ cache: TranscriptCache, _ url: URL, limit: Int) -> [ChatMessage] {
        var out: [[ChatMessage]] = []
        var cursor: String?
        var guardCount = 0
        repeat {
            let p = cache.page(url, cursor: cursor, limit: limit)
            if p.cursor != nil { XCTAssertGreaterThanOrEqual(p.messages.count, limit, "a page short of the limit is the first one") }
            out.append(p.messages)
            if let c = p.cursor { XCTAssertNotEqual(c, cursor, "the cursor moves back") }
            cursor = p.cursor
            guardCount += 1
        } while cursor != nil && guardCount < 100_000
        return out.reversed().flatMap { $0 }
    }

    func assertSame(_ a: [ChatMessage], _ b: [ChatMessage], _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, "\(what): count", file: file, line: line)
        if let i = (0..<min(a.count, b.count)).first(where: { a[$0] != b[$0] }) {
            XCTFail("\(what): first difference at \(i): \(a[i]) vs \(b[i])", file: file, line: line)
        }
    }

    func testTailPagesMatchAFullParse() throws {
        let lines = synthetic(entries: 1000)
        var data = Data(lines.joined(separator: Data([0x0A])))
        data.append(0x0A)
        data.append(Data(#"{"type":"user","uuid":"partial","message":{"content":"half a li"#.utf8))   // still being written
        let url = try write(data)
        let full = ChatFeed.messages(fromLines: lines)
        XCTAssertGreaterThan(full.count, 500)
        XCTAssertTrue(full.contains { $0.toolOK == true } && full.contains { $0.toolOK == false } && full.contains { $0.kind == .tool && $0.toolOK == nil })
        XCTAssertGreaterThan(data.count, 1 << 20, "has huge lines")

        for (window, chunk) in [(UInt64(1 << 10), UInt64(300)), (4 << 10, 64 << 10), (TranscriptHistory.liveWindow, TranscriptHistory.chunk)] {
            for limit in chunk < 1024 ? [1, 3, 50] : [1, 2, 7, 200, 5000] {
                let cache = TranscriptCache(capacity: 4, liveWindow: window, chunk: chunk)
                assertSame(pageAll(cache, url, limit: limit), full, "window \(window) chunk \(chunk) limit \(limit)")
            }
        }
    }

    func testTheNewestPageReadsOnlyTheEnd() throws {
        let lines = synthetic(entries: 1200, seed: 11)
        var data = Data(lines.joined(separator: Data([0x0A])))
        data.append(0x0A)
        let url = try write(data)
        let h = TranscriptHistory(url: url, liveWindow: 64 << 10, chunk: 64 << 10)!
        let page = h.page(cursor: nil, limit: 20)
        let full = ChatFeed.messages(fromLines: lines)
        XCTAssertEqual(page.messages, Array(full.suffix(page.messages.count)))
        XCTAssertGreaterThan(h.head, UInt64(data.count) / 2, "only the end was read")
        let c = try XCTUnwrap(page.cursor.flatMap(TranscriptCursor.init))
        XCTAssertEqual(c.offset, h.feed.parser.lineStarts[h.feed.parser.messages.count - page.messages.count])
    }

    func testFeedCarriesOnAndOlderCallsGetLaterResults() throws {
        // A call early in the file, answered only after the chat is opened from its end.
        let call = json(["type": "assistant", "uuid": "early", "isSidechain": false, "timestamp": "2026-10-08T09:00:00.000Z",
                         "message": ["id": "m0", "content": [["type": "tool_use", "id": "late_answer", "name": "Bash", "input": ["command": "sleep 1000"]]]]])
        let lines = [call] + synthetic(entries: 800, seed: 3)
        var data = Data(lines.joined(separator: Data([0x0A])))
        data.append(0x0A)
        let url = try write(data)
        let cache = TranscriptCache(capacity: 4, liveWindow: 8 << 10, chunk: 8 << 10)
        let (first, feed) = cache.open(url, limit: 5)
        assertSame(first.messages, Array(ChatFeed.messages(fromLines: lines).suffix(first.messages.count)), "newest page")
        XCTAssertTrue(feed.poll().isEmpty, "the feed starts where the page ends")

        // A pending call in the tail window, then results for it and for the early call.
        let tailCall = json(["type": "assistant", "uuid": "tc", "isSidechain": false, "timestamp": "2026-10-08T23:00:00.000Z",
                             "message": ["id": "mt", "content": [["type": "tool_use", "id": "tail_call", "name": "Read", "input": ["file_path": "/x/Y.swift"]]]]])
        try append([tailCall], to: url)
        let added = feed.poll()
        XCTAssertEqual(added.map(\.text), ["Read Y.swift"])
        let results = json(["type": "user", "uuid": "res", "isSidechain": false, "timestamp": "2026-10-08T23:00:01.000Z",
                            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "tail_call", "content": "ok"],
                                                                    ["type": "tool_result", "tool_use_id": "late_answer", "is_error": true, "content": "x"]]]])
        let partial = Data(#"{"type":"user","uuid":"p","message":"#.utf8)
        try append([results], to: url)
        let h = try FileHandle(forWritingTo: url); h.seekToEndOfFile(); h.write(partial); try h.close()
        let updated = feed.poll()
        XCTAssertEqual(updated.map(\.id), [added[0].id])
        XCTAssertEqual(updated.first?.toolOK, true)

        // Reopening and paging back: same as a fresh full parse, the early call included.
        let all = ChatFeed.messages(fromLines: lines + [tailCall, results])
        XCTAssertEqual(all.first?.toolOK, false)
        assertSame(pageAll(cache, url, limit: 37), all, "after appends")
        XCTAssertEqual(cache.open(url).messages, all)
        // Index paging (older phones) still works off the same cache.
        XCTAssertEqual(cache.page(url, before: nil, limit: 3).messages, Array(all.suffix(3)))
        XCTAssertEqual(cache.page(url, before: 10, limit: 4).messages, Array(all[6..<10]))
        XCTAssertEqual(cache.page(url, before: 10, limit: 4).before, 6)
    }

    func testCursorsFromAnotherFileAreRefused() throws {
        let lines = synthetic(entries: 300, seed: 5)
        let url = try write(Data(lines.joined(separator: Data([0x0A]))) + Data([0x0A]))
        let cache = TranscriptCache(capacity: 4, liveWindow: 4 << 10, chunk: 4 << 10)
        let p = cache.page(url, cursor: nil, limit: 10)
        let c = try XCTUnwrap(p.cursor.flatMap(TranscriptCursor.init))
        XCTAssertTrue(cache.page(url, cursor: TranscriptCursor(offset: c.offset, file: c.file &+ 1).string, limit: 10).messages.isEmpty)
        XCTAssertTrue(cache.page(url, cursor: "12", limit: 10).messages.isEmpty)
        XCTAssertNil(cache.page(url, cursor: "garbage", limit: 10).cursor)

        // The file is replaced (rewritten): the cache starts over and old cursors no longer apply.
        let other = synthetic(entries: 50, seed: 9)
        let tmp = try write(Data(other.joined(separator: Data([0x0A]))) + Data([0x0A]))
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        assertSame(pageAll(cache, url, limit: 10), ChatFeed.messages(fromLines: other), "replaced file")
        XCTAssertTrue(cache.page(url, cursor: p.cursor, limit: 10).messages.isEmpty)
    }

    func testRepeatedFixtureWithReusedIds() throws {
        // The fixture chat pasted many times: every uuid and tool id repeats.
        let fixture = Bundle.module.url(forResource: "chat", withExtension: "jsonl", subdirectory: "Fixtures")!
        let one = try Data(contentsOf: fixture).split(separator: 0x0A).map { Data($0) }
        let lines = Array(repeating: one, count: 40).flatMap { $0 }
        let url = try write(Data(lines.joined(separator: Data([0x0A]))) + Data([0x0A]))
        let full = ChatFeed.messages(fromLines: lines)
        for limit in [1, 4, 9] {
            assertSame(pageAll(TranscriptCache(capacity: 2, liveWindow: 512, chunk: 700), url, limit: limit), full, "limit \(limit)")
        }
    }

    func testEmptyAndMissingFiles() throws {
        let cache = TranscriptCache()
        let empty = try write(Data())
        XCTAssertTrue(cache.page(empty, cursor: nil, limit: 10).messages.isEmpty)
        XCTAssertNil(cache.page(empty, cursor: nil, limit: 10).cursor)
        let partial = try write(Data(#"{"type":"user","uuid":"p","message":{"content":"hi there, still typing"#.utf8))
        XCTAssertTrue(cache.open(partial, limit: 10).page.messages.isEmpty)
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString).jsonl")
        XCTAssertTrue(cache.open(missing, limit: 10).page.messages.isEmpty)
        XCTAssertTrue(cache.page(missing, before: nil, limit: 10).messages.isEmpty)
    }

    func testLiveWorkFromTheTailMatchesAFullRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("work-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        urls.append(dir)
        let src = Bundle.module.url(forResource: "s1", withExtension: "jsonl", subdirectory: "Fixtures/work")!
        try FileManager.default.copyItem(at: src, to: dir.appendingPathComponent("s1.jsonl"))
        try FileManager.default.copyItem(at: src.deletingPathExtension(), to: dir.appendingPathComponent("s1"))
        let url = dir.appendingPathComponent("s1.jsonl")
        // Lots of older chat in front, so the live window is a small part of the file.
        let old = synthetic(entries: 2000, seed: 2).filter { $0.count < 10_000 }
        let body = try Data(contentsOf: url)
        try (Data(old.joined(separator: Data([0x0A]))) + Data([0x0A]) + body).write(to: url)

        let full = ChatFeed(url: url)
        _ = full.poll()
        let now = TranscriptScanner.parseISO("2026-10-08T10:00:30.000Z")!
        let (page, feed) = TranscriptCache(capacity: 2, liveWindow: 16 << 10, chunk: 16 << 10).open(url, limit: 5)
        XCTAssertFalse(page.messages.isEmpty)
        XCTAssertEqual(feed.workTracker.live(now: now), full.workTracker.live(now: now))
        XCTAssertFalse(feed.workTracker.live(now: now).agents.isEmpty)
    }
}

/// Small deterministic RNG for the synthetic transcripts.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(_ bound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Int((z ^ (z >> 31)) % UInt64(max(1, bound)))
    }
}
