import XCTest
@testable import WatchCore

final class ScannerTests: XCTestCase {
    func fixture() -> URL { Bundle.module.url(forResource: "transcript", withExtension: "jsonl", subdirectory: "Fixtures")! }

    func scanFixture() -> (TranscriptTail, TokenBuckets) {
        let data = try! Data(contentsOf: fixture())
        let scanner = TranscriptScanner(cacheURL: URL(fileURLWithPath: "/dev/null"), projectsDir: URL(fileURLWithPath: "/nonexistent"))
        var st = FileScanState()
        var b = TokenBuckets()
        for line in data.split(separator: 0x0A) {
            scanner.processLine(Data(line), state: &st, buckets: &b, horizon: .distantPast)
        }
        return (st.tail, b)
    }

    func testParseISO() {
        let d = TranscriptScanner.parseISO("2026-09-28T20:00:05.250Z")!
        XCTAssertEqual(d.timeIntervalSince1970, 1790625605.25, accuracy: 0.001)
    }

    func testStreamedMessageCountedOnce() {
        let (_, b) = scanFixture()
        let total = b.sum(from: .distantPast)
        // Only the final usage of msg_1 counts: 10 + 50 + 100 + 1000.
        XCTAssertEqual(total.raw, 1160, accuracy: 0.01)
        let expected: Double = 10 + 125 + 100 + 250
        XCTAssertEqual(total.weighted, expected, accuracy: 0.01)
    }

    func testRateLimitTail() {
        let (tail, _) = scanFixture()
        XCTAssertEqual(tail.last, .rateLimited)
        XCTAssertEqual(tail.lastRateLimit?.kind, .fiveHour)
        XCTAssertEqual(tail.lastRateLimit?.resetsAt, Date(timeIntervalSince1970: 1790641200))
        XCTAssertNotNil(tail.lastSuccessAt)
        XCTAssertLessThan(tail.lastSuccessAt!, tail.lastRateLimit!.at)
    }
}

final class ForecastTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_790_600_000)

    func samples(_ values: [(Double, Double)], every: TimeInterval = 900) -> [UsageSample] {
        values.enumerated().map { i, v in
            UsageSample(t: t0.addingTimeInterval(Double(i) * every), org: "o", fiveHour: v.0, weekly: v.1)
        }
    }

    func testSlopeProjection() {
        // 10% every 15 min => 40%/h; at 50% it needs 1.25h more.
        let s = samples([(0, 1), (10, 2), (20, 3), (30, 4), (40, 5), (50, 6)])
        let now = s.last!.t
        let f = Forecaster.forecast(samples: s, window: .fiveHour, rateLimits: [], tokens: { _, _ in 0 }, now: now)
        XCTAssertEqual(f.percent, 50)
        XCTAssertEqual(f.ratePerHour!, 40, accuracy: 0.5)
        XCTAssertEqual(f.hitsAt!.timeIntervalSince(now), 1.25 * 3600, accuracy: 120)
        // Window started between the 0% and 10% samples; resets 5h later.
        XCTAssertEqual(f.resetsAt!.timeIntervalSince(t0.addingTimeInterval(450)), 5 * 3600, accuracy: 1)
        XCTAssertFalse(f.resetsFirst)
    }

    func testResetsFirstWhenSlow() {
        let s = samples([(0, 0), (1, 0), (2, 0), (3, 0), (4, 0)])
        let f = Forecaster.forecast(samples: s, window: .fiveHour, rateLimits: [], tokens: { _, _ in 0 }, now: s.last!.t)
        XCTAssertTrue(f.resetsFirst)
    }

    func testWindowRolledOverSinceSample() {
        let s = samples([(90, 10), (100, 11)])
        let hit = RateLimitHit(at: s.last!.t, resetsAt: s.last!.t.addingTimeInterval(600), kind: .fiveHour, text: "")
        let now = s.last!.t.addingTimeInterval(3600)
        let f = Forecaster.forecast(samples: s, window: .fiveHour, rateLimits: [hit], tokens: { _, _ in 0 }, now: now)
        XCTAssertEqual(f.percent, 0)
    }

    func testLearnsTokenRatio() {
        // 1% per 1000 weighted tokens, 1000 tokens per minute.
        let s = samples([(0, 0), (15, 3), (30, 6), (45, 9)])
        let tokens: (Date, Date) -> Double = { a, b in max(0, b.timeIntervalSince(a)) / 60 * 1000 }
        let r = Forecaster.percentPerToken(s, .fiveHour, tokens: tokens, now: s.last!.t)
        XCTAssertEqual(r!, 0.001, accuracy: 0.0001)
        let now = s.last!.t.addingTimeInterval(600)
        let f = Forecaster.forecast(samples: s, window: .fiveHour, rateLimits: [], tokens: tokens, now: now)
        XCTAssertEqual(f.percent!, 55, accuracy: 0.5)   // 45 + 10 min of tokens
    }
}

final class RunnerTests: XCTestCase {
    func testReadsOwnProcessArgs() {
        let (args, env) = Runners.procArgs(getpid())!
        XCTAssertFalse(args.isEmpty)
        XCTAssertTrue(env.contains { $0.hasPrefix("PATH=") })
    }
}

/// Pure due-now logic of the retry engine (the engine itself reads and writes the real state file).
final class RetryDueTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_600_000)

    func item(_ status: RetryItem.Status = .waiting, resetsIn: TimeInterval = 3600, attempts: Int = 0) -> RetryItem {
        RetryItem(sessionId: "local_1", cliSessionId: nil, profileId: "p", title: "t", cwd: "/", failedAt: now.addingTimeInterval(-600),
                  resetsAt: now.addingTimeInterval(resetsIn), status: status, attempts: attempts,
                  lastAttemptAt: nil, lastMode: nil, note: nil)
    }

    func testWaitsForResetAndDelay() {
        XCTAssertFalse(RetryEngine.isDue(item(resetsIn: 3600), limitedUntil: nil, retryDelay: 60, now: now))
        XCTAssertFalse(RetryEngine.isDue(item(resetsIn: -30), limitedUntil: nil, retryDelay: 60, now: now))
        XCTAssertTrue(RetryEngine.isDue(item(resetsIn: -90), limitedUntil: nil, retryDelay: 60, now: now))
        // Past its own reset but the account is still limited.
        XCTAssertFalse(RetryEngine.isDue(item(resetsIn: -90), limitedUntil: now.addingTimeInterval(600), retryDelay: 60, now: now))
        XCTAssertTrue(RetryEngine.isDue(item(resetsIn: -90), limitedUntil: now.addingTimeInterval(-1), retryDelay: 60, now: now))
    }

    func testForcedWaitingItemIsDueWhileLimited() {
        var it = item(resetsIn: 3600, attempts: 1)
        XCTAssertTrue(RetryEngine.forceDue(&it))
        XCTAssertEqual(it.status, .waiting)
        XCTAssertEqual(it.attempts, 1)
        XCTAssertTrue(RetryEngine.isDue(it, limitedUntil: now.addingTimeInterval(3600), retryDelay: 60, now: now))
        XCTAssertTrue(RetryEngine.isDue(it, limitedUntil: .distantFuture, retryDelay: 60, now: now))
    }

    func testFailedItemStartsOver() {
        var it = item(.failed, resetsIn: -7200, attempts: 3)
        XCTAssertFalse(RetryEngine.isDue(it, limitedUntil: nil, retryDelay: 60, now: now))
        XCTAssertTrue(RetryEngine.forceDue(&it))
        XCTAssertEqual(it.status, .waiting)
        XCTAssertEqual(it.attempts, 0)
        XCTAssertTrue(RetryEngine.isDue(it, limitedUntil: now.addingTimeInterval(3600), retryDelay: 60, now: now))
    }

    func testInFlightAndFinishedItemsCantBeForced() {
        for s in [RetryItem.Status.running, .verifying, .done, .resolved] {
            var it = item(s)
            XCTAssertFalse(RetryEngine.forceDue(&it), s.rawValue)
            XCTAssertEqual(it, item(s))
            XCTAssertFalse(RetryEngine.isDue(it, limitedUntil: nil, retryDelay: 0, now: now.addingTimeInterval(7200)))
        }
    }

    func testOwnPromptIsNotAManualContinue() {
        var it = item()
        var tail = TranscriptTail(last: .userPrompt, lastAt: now)
        XCTAssertTrue(RetryEngine.continuedManually(it, tail: tail))       // never sent: the user typed it
        it.lastAttemptAt = now.addingTimeInterval(-5)
        XCTAssertFalse(RetryEngine.continuedManually(it, tail: tail))      // probably our "continue"
        tail.last = .assistantDone
        XCTAssertTrue(RetryEngine.continuedManually(it, tail: tail))
        tail.last = .rateLimited
        XCTAssertFalse(RetryEngine.continuedManually(it, tail: tail))
    }
}

/// Requests forwarded to the retry engine owner through the retry-request file.
final class RetryRequestTests: XCTestCase {
    func testParsesOldSingleValueFiles() {
        XCTAssertEqual(RetryRequest.parse(""), [])     // mid-write: nothing, not "all"
        XCTAssertEqual(RetryRequest.parse("*"), [.all])
        XCTAssertEqual(RetryRequest.parse("work"), [.profile("work")])
        XCTAssertEqual(RetryRequest.parse("item:local_1"), [.item("local_1")])
        XCTAssertEqual(RetryRequest.parse("  item:local_1 \n"), [.item("local_1")])
    }

    func testParsesOneRequestPerLine() {
        XCTAssertEqual(RetryRequest.parse("item:a\nwork\n\n*\ndismiss:a@1\n"),
                       [.item("a"), .profile("work"), .all, .dismiss("a@1")])
    }

    func testLineRoundTrips() {
        for r in [RetryRequest.all, .profile("p"), .item("local_1@17"), .dismiss("local_1@17")] {
            XCTAssertEqual(RetryRequest.parse(r.line), [r])
        }
    }

    func testAppendedRequestsAreAllTakenOnce() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("retry-request")
        XCTAssertEqual(RetryRequest.take(from: url), [])
        RetryRequest.append(.item("a"), to: url)
        RetryRequest.append(.item("b"), to: url)
        RetryRequest.append(.profile("work"), to: url)
        XCTAssertEqual(RetryRequest.take(from: url), [.item("a"), .item("b"), .profile("work")])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
        XCTAssertEqual(RetryRequest.take(from: url), [])
        // A file written by an older binary (atomic write, no newline).
        try "item:c".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(RetryRequest.take(from: url), [.item("c")])
    }
}

/// Picking, sending and budgeting of queued retries.
final class RetrySendTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_600_000)

    func item(_ sid: String, resetsIn: TimeInterval = -3600, attempts: Int = 0) -> RetryItem {
        RetryItem(sessionId: sid, cliSessionId: nil, profileId: "p", title: sid, cwd: "/", failedAt: now.addingTimeInterval(-7200),
                  resetsAt: now.addingTimeInterval(resetsIn), status: .waiting, attempts: attempts,
                  lastAttemptAt: nil, lastMode: nil, note: nil)
    }

    func testMissingChatDoesNotBlockTheQueue() {
        var a = item("gone"); _ = RetryEngine.forceDue(&a)
        let items = [a, item("later", resetsIn: 3600), item("ok")]
        let pick = RetryEngine.pickDue(items, isDue: { $0.status == .waiting && ($0.resetsAt ?? now) <= now },
                                       hasChat: { $0.sessionId != "gone" })
        XCTAssertEqual(pick.missing, [0])
        XCTAssertEqual(pick.send, 2)
    }

    func testNothingDue() {
        let pick = RetryEngine.pickDue([item("a", resetsIn: 3600)], isDue: { _ in false }, hasChat: { _ in true })
        XCTAssertEqual(pick.missing, [])
        XCTAssertNil(pick.send)
    }

    func testManualSendsDontUseTheAttemptBudget() {
        let max = 3
        var it = item("a", resetsIn: 3600)
        for _ in 0..<5 {
            _ = RetryEngine.forceDue(&it)
            RetryEngine.beginSend(&it, mode: .ui, now: now)
            XCTAssertEqual(it.attempts, 0)
            XCTAssertFalse(RetryEngine.outOfAttempts(it, max: max))
            it.status = .waiting
            it.resetsAt = now.addingTimeInterval(600)   // back to waiting for the reset
        }
        // After the reset it still gets all its automatic attempts.
        for n in 1...max {
            RetryEngine.beginSend(&it, mode: .ui, now: now)
            XCTAssertEqual(it.attempts, n)
            XCTAssertEqual(RetryEngine.outOfAttempts(it, max: max), n == max)
            it.status = .waiting
        }
    }

    func testManualSendAtFullBudgetDoesNotGiveUp() {
        var it = item("a", attempts: 3)
        _ = RetryEngine.forceDue(&it)
        RetryEngine.beginSend(&it, mode: .cli, now: now)
        XCTAssertEqual(it.attempts, 3)
        XCTAssertFalse(RetryEngine.outOfAttempts(it, max: 3))
        XCTAssertEqual(it.status, .verifying)
        XCTAssertEqual(it.lastMode, .cli)
        XCTAssertEqual(it.lastAttemptAt, now)
    }

    func testRetryNowWithModeOffSendsViaUIOnce() {
        var it = item("a", resetsIn: 3600)
        XCTAssertNil(RetryEngine.sendMode(for: it, configured: .off))     // automatic: leave it to the user
        XCTAssertEqual(RetryEngine.sendMode(for: it, configured: .cli), .cli)
        _ = RetryEngine.forceDue(&it)
        XCTAssertEqual(RetryEngine.sendMode(for: it, configured: .off), .ui)
        XCTAssertEqual(RetryEngine.sendMode(for: it, configured: .cli), .cli)
    }
}
