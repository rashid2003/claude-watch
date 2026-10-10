import XCTest
import WatchProtocol
@testable import WatchCore

struct FixedRandom: BuddyRandom {
    var values: [Double]; var i = 0
    init(_ v: [Double]) { values = v }
    mutating func unit() -> Double { defer { i += 1 }; return values[i % values.count] }
}

final class BuddyLifeMindTests: XCTestCase {
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    func date(hour: Int, day: Int = 10) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: 30))!
    }

    func testHourWindowsWrapMidnight() {
        XCTAssertTrue(BuddyLife.inHours(23, [22, 7]))
        XCTAssertTrue(BuddyLife.inHours(3, [22, 7]))
        XCTAssertFalse(BuddyLife.inHours(12, [22, 7]))
        XCTAssertTrue(BuddyLife.inHours(12, nil))
        XCTAssertFalse(BuddyLife.inHours(7, [7, 7 + 0]) == false)   // from == to means always
    }

    func testNightSleepsAndDaytimeNeverSleepsDeep() {
        let cfg = BuddyLifeConfig.defaults(for: nil)
        var night = FixedRandom([0.5])
        // At 2 a.m. only idle/explore/read/stretch and the night sleep are allowed (no eating, movie, dance).
        for r in stride(from: 0.0, to: 1.0, by: 0.05) {
            var rng = FixedRandom([r, 0.5])
            let a = BuddyLife.pick(cfg, now: date(hour: 2), calendar: cal, rng: &rng).activity
            XCTAssertFalse([.eat, .movie, .dance].contains(a), "\(a) at 2am")
        }
        _ = BuddyLife.pick(cfg, now: date(hour: 2), calendar: cal, rng: &night)
        var seen = Set<BuddyActivity>()
        for r in stride(from: 0.0, to: 1.0, by: 0.02) {
            var rng = FixedRandom([r, 0.5])
            seen.insert(BuddyLife.pick(cfg, now: date(hour: 18), calendar: cal, rng: &rng).activity)
        }
        XCTAssertTrue(seen.contains(.movie) && seen.contains(.eat))
        XCTAssertFalse(seen.contains(.sleep))
    }

    func testMovieAndFoodGetADetailAndDurationInRange() {
        var cfg = BuddyLifeConfig.defaults(for: nil)
        cfg.routine = [.init(.movie, weight: 1, seconds: [60, 120])]
        var rng = FixedRandom([0.0, 0.5, 0.0])
        let s = BuddyLife.pick(cfg, now: date(hour: 20), calendar: cal, rng: &rng)
        XCTAssertEqual(s.activity, .movie)
        XCTAssertEqual(s.detail, cfg.movies[0])
        XCTAssertEqual(s.endsAt.timeIntervalSince(s.startedAt), 90, accuracy: 0.01)
    }

    func testEmptyRoutineFallsBackToIdle() {
        var cfg = BuddyLifeConfig.defaults(for: nil); cfg.routine = []
        var rng = SystemBuddyRandom()
        XCTAssertEqual(BuddyLife.pick(cfg, now: date(hour: 12), calendar: cal, rng: &rng).activity, .idle)
    }

    func testLifeJSONWithMissingKeysKeepsDefaults() throws {
        let cfg = try JSONDecoder().decode(BuddyLifeConfig.self, from: Data(#"{"movies":["Heat"],"routine":[{"activity":"eat"}]}"#.utf8))
        XCTAssertEqual(cfg.movies, ["Heat"])
        XCTAssertEqual(cfg.routine.first?.weight, 1)
        XCTAssertFalse(cfg.foods.isEmpty)
    }

    // MARK: Mind

    func mind() -> BuddyMindConfig { BuddyMindConfig.defaults(for: nil) }

    func testMindWaitsInQuietHoursAndWhenTooSoonOrEnoughForToday() {
        var rng = SystemBuddyRandom()
        let cfg = mind()
        XCTAssertNil(BuddyMind.plan(cfg, memory: BuddyMemory(), now: date(hour: 23), calendar: cal, rng: &rng))
        XCTAssertNotNil(BuddyMind.plan(cfg, memory: BuddyMemory(), now: date(hour: 12), calendar: cal, rng: &rng))
        var m = BuddyMemory(); m.lastLearnAt = date(hour: 12).addingTimeInterval(-600)
        XCTAssertNil(BuddyMind.plan(cfg, memory: m, now: date(hour: 12), calendar: cal, rng: &rng))
        XCTAssertNotNil(BuddyMind.plan(cfg, memory: m, now: date(hour: 12), calendar: cal, ignoringPause: true, rng: &rng))
        var full = BuddyMemory()
        for i in 0..<cfg.limits.maxLearnsPerDay {
            full.add(BuddyFinding(id: "\(i)", at: date(hour: 9), topic: "t", finding: "f", tip: "", source: "", interest: 3, isFollow: false, told: false, read: true))
        }
        XCTAssertNil(BuddyMind.plan(cfg, memory: full, now: date(hour: 12), calendar: cal, ignoringPause: true, rng: &rng))
        var off = cfg; off.enabled = false
        XCTAssertNil(BuddyMind.plan(off, memory: BuddyMemory(), now: date(hour: 12), calendar: cal, rng: &rng))
    }

    func testDueFollowComesFirstThenInterests() {
        var rng = FixedRandom([0.0])
        let cfg = mind()
        let first = BuddyMind.plan(cfg, memory: BuddyMemory(), now: date(hour: 12), calendar: cal, rng: &rng)
        XCTAssertNotNil(first?.follow)
        var m = BuddyMemory(); m.followChecks[cfg.follows[0].topic] = date(hour: 9)   // checked 3 h ago, due in 24 h
        let next = BuddyMind.plan(cfg, memory: m, now: date(hour: 12), calendar: cal, rng: &rng)
        XCTAssertNil(next?.follow)
        XCTAssertEqual(next?.topic, cfg.interests[0])
    }

    func testParsesCLIEnvelopeWithCodeFence() {
        let inner = "Here you go:\n```json\n{\"topic\":\"T\",\"finding\":\"Wow {braces} here\",\"tip\":\"x\",\"interest\":4,\"new\":true}\n```"
        let env = try! JSONSerialization.data(withJSONObject: ["type": "result", "is_error": false, "result": inner])
        let a = BuddyMind.parse(cliOutput: String(data: env, encoding: .utf8)!)
        XCTAssertEqual(a?.finding, "Wow {braces} here")
        XCTAssertEqual(a?.interest, 4)
        XCTAssertNil(BuddyMind.parse(cliOutput: "not json"))
        let bad = try! JSONSerialization.data(withJSONObject: ["is_error": true, "result": "{\"topic\":\"a\",\"finding\":\"b\"}"])
        XCTAssertNil(BuddyMind.parse(cliOutput: String(data: bad, encoding: .utf8)!))
    }

    func testRecordTellsFollowsAndSkipsNoNews() {
        let cfg = mind()
        let plan = BuddyPlan(topic: cfg.follows[0].topic, follow: cfg.follows[0])
        var m = BuddyMemory()
        let none = BuddyMind.Answer(topic: "t", finding: "nothing", tip: nil, source: nil, interest: 1, new: false, nextInterests: nil)
        XCTAssertNil(BuddyMind.record(answer: none, cfg: cfg, memory: &m, plan: plan, now: date(hour: 12), calendar: cal))
        XCTAssertNotNil(m.followChecks[cfg.follows[0].topic])
        XCTAssertTrue(m.learned.isEmpty)
        let news = BuddyMind.Answer(topic: "New film", finding: "A film!", tip: "Watch it", source: "u", interest: 1, new: true, nextInterests: ["a", "b", "c"])
        let f = BuddyMind.record(answer: news, cfg: cfg, memory: &m, plan: plan, now: date(hour: 12), calendar: cal)
        XCTAssertEqual(f?.told, true)               // "always" tells even at low interest
        XCTAssertEqual(m.discovered, ["a", "b"])
        // An ordinary interest below the bar is saved but not announced.
        let calm = BuddyMind.Answer(topic: "x", finding: "y", tip: nil, source: nil, interest: 2, new: nil, nextInterests: nil)
        let g = BuddyMind.record(answer: calm, cfg: cfg, memory: &m, plan: BuddyPlan(topic: "space", follow: nil), now: date(hour: 12), calendar: cal)
        XCTAssertEqual(g?.told, false)
        XCTAssertEqual(m.unread.count, 2)
    }

    func testMindOnlyGetsWebTools() {
        let args = BuddyMindRunner.arguments(prompt: "p", cfg: mind())
        let i = args.firstIndex(of: "--tools")!
        XCTAssertEqual(args[i + 1], "WebSearch,WebFetch")
        XCTAssertTrue(args.contains("--no-session-persistence"))
        XCTAssertTrue(args.contains("--strict-mcp-config"))
        XCTAssertFalse(args.joined(separator: " ").contains("Bash"))
        let env = BuddyMindRunner.environment(base: ["CLAUDECODE": "1", "ANTHROPIC_API_KEY": "k", "PATH": "/bin"], cfg: mind())
        XCTAssertNil(env["CLAUDECODE"]); XCTAssertNil(env["ANTHROPIC_API_KEY"]); XCTAssertEqual(env["CLAUDE_WATCH_HEADLESS"], "1")
    }

    func testFilesCreateDefaultsAndReportBrokenJSON() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = BuddyFiles(character: "blobby", root: root)
        let first = files.load(files.mind, fallback: BuddyMindConfig.defaults(for: nil))
        XCTAssertNil(first.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.mind.path))
        // user edits it
        var edited = first.value; edited.interests = ["trains"]
        files.save(edited, to: files.mind)
        XCTAssertEqual(files.load(files.mind, fallback: BuddyMindConfig.defaults(for: nil)).value.interests, ["trains"])
        // user breaks it: defaults are used, file is untouched, error explains
        try Data("{ nope".utf8).write(to: files.mind)
        let broken = files.load(files.mind, fallback: BuddyMindConfig.defaults(for: nil))
        XCTAssertNotNil(broken.error)
        XCTAssertEqual(try String(contentsOf: files.mind, encoding: .utf8), "{ nope")
        // memory round-trips dates
        var mem = BuddyMemory(); mem.lastLearnAt = date(hour: 5)
        files.save(mem, to: files.memory)
        XCTAssertEqual(files.load(files.memory, fallback: BuddyMemory()).value.lastLearnAt, date(hour: 5))
    }
}
