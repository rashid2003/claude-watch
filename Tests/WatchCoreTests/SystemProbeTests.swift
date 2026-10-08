import XCTest
@testable import WatchCore

final class SystemProbeTests: XCTestCase {
    func testReadingsAreSane() {
        let m = SystemProbe.memory()
        XCTAssertGreaterThan(m.total, 1 << 30)
        XCTAssertGreaterThan(m.used, 0)
        XCTAssertLessThanOrEqual(m.used, m.total)
        let d = SystemProbe.disk()
        XCTAssertGreaterThan(d.total, d.free)
        XCTAssertGreaterThan(d.free, 0)
        XCTAssertGreaterThan(SystemProbe.load().five, 0)
        let s = SystemProbe.swap()
        XCTAssertGreaterThanOrEqual(s.total, s.used)

        let scan = ProcessScan()
        _ = scan.sample()
        var x = 0.0
        for i in 0..<3_000_000 { x += sqrt(Double(i)) }   // burn a little CPU so this process shows some
        XCTAssertGreaterThan(x, 0)
        let me = scan.sample().first { $0.0.pid == getpid() }
        XCTAssertNotNil(me)
        XCTAssertGreaterThan(me?.0.footprint ?? 0, 0)
        XCTAssertGreaterThan(me?.cpu ?? 0, 0)
    }

    func testSystemWatchProducesAReading() {
        let w = SystemWatch(config: { SystemConfig() }, profiles: { [] })
        let got = expectation(description: "sample")
        got.assertForOverFulfill = false
        w.onSample = { _ in got.fulfill() }
        w.start()
        wait(for: [got], timeout: 8)
        w.stop()
        let h = w.latest
        XCTAssertGreaterThan(h?.memTotal ?? 0, 0)
        XCTAssertFalse(h?.apps.isEmpty ?? true)
        XCTAssertEqual(h?.history.count, 1)
        print("system:", h.map { "\($0.level) \($0.reasons) mem \(SystemText.gb($0.memUsed))/\(SystemText.gb($0.memTotal)) swap \(SystemText.gb($0.swapUsed))/\(SystemText.gb($0.swapTotal)) disk \(SystemText.gb($0.diskFree)) load \($0.load5)" } ?? "-")
        print("apps:", h?.apps.prefix(6).map { "\($0.name) \(SystemText.gb($0.rss)) \(Int($0.cpu))% x\($0.processes)" } ?? [])
    }
}
