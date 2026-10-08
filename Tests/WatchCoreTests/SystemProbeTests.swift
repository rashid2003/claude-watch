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
}
