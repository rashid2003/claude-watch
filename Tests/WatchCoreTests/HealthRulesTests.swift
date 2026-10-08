import XCTest
@testable import WatchCore
import WatchProtocol

final class HealthRulesTests: XCTestCase {
    let GB: Int64 = 1_000_000_000

    func inputs(pressure: HealthLevel = .ok, swap: (Int64, Int64) = (0, 0), disk: Int64 = 500, load5: Double = 1,
                thermal: ProcessInfo.ThermalState = .nominal) -> HealthInputs {
        HealthInputs(pressure: pressure, swapUsed: swap.0 * GB / 10, swapTotal: swap.1 * GB / 10, diskFree: disk * GB,
                     load5: load5, cores: 10, thermal: thermal)
    }

    func testAllOk() {
        let r = HealthRules.evaluate(inputs(), SystemConfig())
        XCTAssertEqual(r.level, .ok)
        XCTAssertEqual(r.reasons, [])
    }

    func testLastCrashLooksCritical() {
        let r = HealthRules.evaluate(inputs(swap: (96, 100), disk: 7, load5: 46), SystemConfig())
        XCTAssertEqual(r.level, .critical)
        XCTAssertEqual(r.reasons, ["swap 9.6/10 GB", "disk 7 GB free", "load 46 on 10 cores"])
    }

    func testWarnThresholds() {
        XCTAssertEqual(HealthRules.evaluate(inputs(swap: (80, 100)), SystemConfig()).level, .warn)
        XCTAssertEqual(HealthRules.evaluate(inputs(disk: 40), SystemConfig()).level, .warn)
        XCTAssertEqual(HealthRules.evaluate(inputs(load5: 25), SystemConfig()).level, .warn)
        XCTAssertEqual(HealthRules.evaluate(inputs(pressure: .warn), SystemConfig()).level, .warn)
        XCTAssertEqual(HealthRules.evaluate(inputs(thermal: .serious), SystemConfig()).level, .warn)
        XCTAssertEqual(HealthRules.evaluate(inputs(thermal: .critical), SystemConfig()).level, .critical)
        XCTAssertEqual(HealthRules.evaluate(inputs(swap: (5, 8)), SystemConfig()).level, .ok, "under 1 GB of swap is ignored")
        var cfg = SystemConfig()
        cfg.diskWarnGB = 30
        XCTAssertEqual(HealthRules.evaluate(inputs(disk: 40), cfg).level, .ok)
    }

    func testCriticalReasonsComeFirst() {
        let r = HealthRules.evaluate(inputs(swap: (80, 100), disk: 10), SystemConfig())
        XCTAssertEqual(r.reasons, ["disk 10 GB free", "swap 8.0/10 GB"])
    }

    func testAlerterHoldsEscalatesAndRearms() {
        var a = HealthAlerter()
        let t0 = Date(timeIntervalSince1970: 0)
        func feed(_ l: HealthLevel, _ s: Double) -> HealthLevel? { a.feed(l, at: t0 + s, autoEnabled: false, autoAfter: 120).alert }
        XCTAssertNil(feed(.warn, 0))
        XCTAssertNil(feed(.warn, 30), "not held long enough")
        XCTAssertEqual(feed(.warn, 60), .warn)
        XCTAssertNil(feed(.warn, 65), "alerts once")
        XCTAssertNil(feed(.critical, 70))
        XCTAssertEqual(feed(.critical, 130), .critical, "escalation alerts")
        XCTAssertNil(feed(.ok, 140))
        XCTAssertNil(feed(.ok, 200))
        XCTAssertNil(feed(.critical, 300))
        XCTAssertNil(feed(.critical, 360), "same level within the re-arm window")
        XCTAssertNil(feed(.ok, 400))
        XCTAssertNil(feed(.ok, 460))
        XCTAssertNil(feed(.ok, 460 + 1800))
        XCTAssertNil(feed(.warn, 2400))
        XCTAssertEqual(feed(.warn, 2460), .warn, "re-armed after 30 min below")
    }

    func testAutoActFiresOnceAfterDelay() {
        var a = HealthAlerter()
        let t0 = Date(timeIntervalSince1970: 0)
        func auto(_ l: HealthLevel, _ s: Double) -> Bool { a.feed(l, at: t0 + s, autoEnabled: true, autoAfter: 120).autoAct }
        XCTAssertFalse(auto(.critical, 0))
        XCTAssertFalse(auto(.critical, 60))   // confirmed here
        XCTAssertFalse(auto(.critical, 170))
        XCTAssertTrue(auto(.critical, 180))
        XCTAssertFalse(auto(.critical, 400), "once per critical episode")
        XCTAssertFalse(auto(.warn, 410))
        XCTAssertFalse(auto(.warn, 470))
        XCTAssertFalse(auto(.critical, 500))
        XCTAssertFalse(auto(.critical, 560))
        XCTAssertTrue(auto(.critical, 680))

        var b = HealthAlerter()
        XCTAssertFalse(b.feed(.critical, at: t0, autoEnabled: false, autoAfter: 0).autoAct)
        XCTAssertFalse(b.feed(.critical, at: t0 + 600, autoEnabled: false, autoAfter: 0).autoAct, "disabled")
    }

    func testAlertText() {
        let apps = [("Docker", 6_100_000_000), ("qemu-system-aarch64", 1_900_000_000), ("Finder", 100_000_000)].map { n, b in
            AppUsage(id: n, name: n, rss: Int64(b), cpu: 0, processes: 1, pids: [], mainPid: 2, canQuit: false, canKill: true)
        }
        XCTAssertEqual(SystemText.body(reasons: ["swap 9.6/10 GB", "disk 18 GB free"], apps: apps),
                       "swap 9.6/10 GB · disk 18 GB free — Docker 6.1 GB, qemu-system-aarch64 1.9 GB")
        XCTAssertEqual(SystemText.title(.critical, reasons: ["swap 9.6/10 GB"]), "Mac critical: swap 9.6/10 GB")
        XCTAssertEqual(SystemText.title(.warn, reasons: []), "Mac under pressure")
        XCTAssertEqual(SystemText.gb(14_200_000_000), "14.2 GB")
    }
}
