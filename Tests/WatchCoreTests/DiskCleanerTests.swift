import XCTest
@testable import WatchCore

final class DiskCleanerTests: XCTestCase {
    var home: URL!

    override func setUp() {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("dc-\(UUID().uuidString)")
        let dd = home.appendingPathComponent("Library/Developer/Xcode/DerivedData/App-abc")
        try! FileManager.default.createDirectory(at: dd, withIntermediateDirectories: true)
        try! Data(count: 300_000).write(to: dd.appendingPathComponent("blob"))
        let npm = home.appendingPathComponent(".npm/_cacache")
        try! FileManager.default.createDirectory(at: npm, withIntermediateDirectories: true)
        try! Data(count: 100_000).write(to: npm.appendingPathComponent("x"))
    }

    override func tearDown() { try? FileManager.default.removeItem(at: home) }

    func testMeasureAndClean() throws {
        let c = DiskCleaner(home: home, run: { _, _ in (0, #"{"devices":{}}"#) })
        let t = c.measure()
        XCTAssertEqual(Set(t.map(\.id)), ["derivedData", "npm"])
        XCTAssertGreaterThanOrEqual(t.first { $0.id == "derivedData" }!.bytes, 300_000)
        XCTAssertEqual(t.first { $0.id == "npm" }?.label, "npm cache")

        let r = c.clean(["derivedData", "npm"])
        XCTAssertEqual(r.errors, [])
        XCTAssertGreaterThanOrEqual(r.freed, 400_000)
        let dd = home.appendingPathComponent("Library/Developer/Xcode/DerivedData").path
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dd), [], "keeps the folder, empties it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".npm/_cacache").path))
        XCTAssertEqual(c.measure().map(\.id), [])
    }

    func testUnknownIdAndFailingTrash() {
        let c = DiskCleaner(home: home, run: { _, _ in (1, "") })
        XCTAssertEqual(c.clean(["nope"]).errors, ["Unknown target nope"])
        XCTAssertEqual(c.clean(["trash"]).errors.count, 1)
    }

    func testSimulatorsAreMeasuredFromSimctl() throws {
        let dev = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices/ABC")
        try FileManager.default.createDirectory(at: dev, withIntermediateDirectories: true)
        try Data(count: 50_000).write(to: dev.appendingPathComponent("disk"))
        let json = #"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-17-0":[{"udid":"ABC","name":"iPhone 15"}]}}"#
        let c = DiskCleaner(home: home, run: { _, args in args.contains("list") ? (0, json) : (0, "") })
        XCTAssertGreaterThanOrEqual(c.measure().first { $0.id == "simulators" }?.bytes ?? 0, 50_000)
    }
}
