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

    func testSystemConfigDefaultsAndPartialDecode() throws {
        let empty = try JSONCoder.decoder.decode(Config.self, from: Data("{}".utf8))
        XCTAssertEqual(empty.system.diskWarnGB, 50)
        XCTAssertEqual(empty.system.diskCriticalGB, 20)
        XCTAssertFalse(empty.system.auto.enabled)
        XCTAssertEqual(empty.system.auto.afterSeconds, 120)
        let json = #"{"system":{"auto":{"enabled":true,"quitApps":["qemu-system-aarch64"],"cleanTargets":["trash","npm"]}}}"#
        let partial = try JSONCoder.decoder.decode(Config.self, from: Data(json.utf8))
        XCTAssertTrue(partial.system.auto.enabled)
        XCTAssertEqual(partial.system.auto.quitApps, ["qemu-system-aarch64"])
        XCTAssertEqual(partial.system.auto.cleanTargets, ["npm"], "trash is never auto-emptied")
        XCTAssertEqual(partial.system.diskWarnGB, 50)
        XCTAssertEqual(partial.system.auto.afterSeconds, 120)
    }
}
