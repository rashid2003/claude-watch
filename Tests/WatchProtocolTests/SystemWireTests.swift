import XCTest
@testable import WatchProtocol

final class SystemWireTests: XCTestCase {
    static func sample(history: Int = 3) -> SystemHealth {
        SystemHealth(at: Date(timeIntervalSince1970: 1_790_600_000), level: .warn, reasons: ["swap 8/10 GB"],
                     pressure: .ok, memTotal: 32 << 30, memUsed: 20 << 30, memCompressed: 3 << 30,
                     swapUsed: 8 << 30, swapTotal: 10 << 30, diskFree: 80 << 30, diskTotal: 994 << 30,
                     load1: 6, load5: 5, cores: 10, thermal: "nominal",
                     apps: [AppUsage(id: "/Applications/Docker.app", name: "Docker", rss: 6 << 30, cpu: 40, processes: 7,
                                     pids: [501, 502], mainPid: 501, canQuit: true, canKill: true)],
                     cleanable: [CleanTarget(id: "derivedData", label: "Xcode DerivedData", bytes: 14 << 30)],
                     history: (0..<history).map { HealthPoint(at: Date(timeIntervalSince1970: Double(1_790_600_000 + $0 * 5)),
                                                             memUsed: 1, swapUsed: 2, diskFree: 3, load1: 4) },
                     auto: AutoActSummary(enabled: false, afterSeconds: 120, quitApps: [], closeIdleClaude: false, cleanTargets: []))
    }

    func testSystemHealthRoundTrip() throws {
        let h = Self.sample()
        let back = try WireCoder.decoder.decode(SystemHealth.self, from: WireCoder.encoder.encode(h))
        XCTAssertEqual(back, h)
        XCTAssertEqual(h.latestOnly.history.count, 1)
        XCTAssertEqual(h.latestOnly.history.first, h.history.last)
    }

    func testLevelOrdering() {
        XCTAssertLessThan(HealthLevel.ok, .warn)
        XCTAssertLessThan(HealthLevel.warn, .critical)
        XCTAssertEqual([HealthLevel.warn, .critical, .ok].max(), .critical)
    }

    func testServerMessageAndClientKinds() throws {
        let m = WSServerMessage.system(Self.sample(history: 1))
        let back = try WireCoder.decoder.decode(WSServerMessage.self, from: WireCoder.encoder.encode(m))
        guard case .system(let h) = back else { return XCTFail("wrong case") }
        XCTAssertEqual(h.apps.first?.name, "Docker")
        let c = try WireCoder.decoder.decode(WSClientMessage.self, from: Data(#"{"type":"watchSystem"}"#.utf8))
        XCTAssertEqual(c.type, .watchSystem)
    }

    func testSnapshotWithoutSystemLevelDecodes() throws {
        let json = #"{"at":1790600000,"accounts":[],"queue":[],"engineOwner":true,"scanning":false}"#
        let s = try WireCoder.decoder.decode(Snapshot.self, from: Data(json.utf8))
        XCTAssertNil(s.systemLevel)
        var t = s; t.systemLevel = .critical
        XCTAssertEqual(try WireCoder.decoder.decode(Snapshot.self, from: WireCoder.encoder.encode(t)).systemLevel, .critical)
    }
}
