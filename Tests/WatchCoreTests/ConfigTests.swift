import XCTest
@testable import WatchCore

final class ConfigTests: XCTestCase {
    func testAppearanceDefaultsWhenMissing() throws {
        // A config.json written before the Mac app had a main window.
        let old = #"{"pollSeconds": 20, "defaultRetryMode": "cli", "retryMessage": "go on"}"#
        let cfg = try JSONCoder.decoder.decode(Config.self, from: Data(old.utf8))
        XCTAssertTrue(cfg.showInMenuBar)
        XCTAssertTrue(cfg.showInDock)
        XCTAssertEqual(cfg.pollSeconds, 20)
        XCTAssertEqual(cfg.defaultRetryMode, .cli)
        XCTAssertEqual(cfg.retryMessage, "go on")
        XCTAssertEqual(cfg.bridgePort, 7433)
    }

    func testRoundTripThroughFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var cfg = Config()
        cfg.showInMenuBar = false
        cfg.showInDock = true
        cfg.defaultRetryMode = .off
        cfg.retryMessage = "keep going"
        cfg.retryDelaySeconds = 90
        cfg.maxAttempts = 5
        cfg.maxFailureAgeHours = 6
        cfg.warnBeforeCapMinutes = 15
        cfg.pollSeconds = 30
        cfg.bridgeEnabled = false
        cfg.bridgePort = 7500
        cfg.requireTailnetOwner = false
        cfg.keepAwakeWhenPaired = true
        cfg.keepAwakeOnlyOnAC = false
        cfg.profiles["p1"] = ProfileConfig(name: "Work", retryMode: .cli)
        try cfg.save(to: url)

        let back = try XCTUnwrap(Config.load(from: url))
        XCTAssertEqual(back, cfg)
        XCTAssertFalse(back.showInMenuBar)
        XCTAssertTrue(back.showInDock)

        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(json["showInMenuBar"] as? Bool, false)
        XCTAssertEqual(json["showInDock"] as? Bool, true)
    }

    func testUnreadableFileLoadsAsNil() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{ not json".utf8).write(to: url)
        XCTAssertNil(Config.load(from: url))
    }
}
