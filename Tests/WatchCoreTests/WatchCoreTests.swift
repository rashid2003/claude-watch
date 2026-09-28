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
