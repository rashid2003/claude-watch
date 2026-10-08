import AppKit
import XCTest
@testable import WatchCore

/// Quits and kills real processes: `SYSTEM_LIVE=1 swift test --filter SystemActionsLiveTests`.
final class SystemActionsLiveTests: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["SYSTEM_LIVE"] != nil else { throw XCTSkip("SYSTEM_LIVE not set") }
    }

    func testKillALooseProcessAndRefuseProtectedOnes() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["600"]
        try p.run()
        let r = SystemActions.run(.kill(p.processIdentifier), snapshot: nil, apps: [])
        XCTAssertTrue(r.ok, r.message)
        p.waitUntilExit()
        XCTAssertEqual(p.terminationReason, .uncaughtSignal)
        XCTAssertFalse(SystemActions.run(.kill(1), snapshot: nil, apps: []).ok)
    }

    func testQuitByProcessName() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["601"]
        try p.run()
        let r = SystemActions.run(.quitApp("sleep"), snapshot: nil, apps: [])
        XCTAssertTrue(r.ok, r.message)
        XCTAssertFalse(p.isRunning)
    }

    func testQuitAnApp() throws {
        let url = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let opened = expectation(description: "open")
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in opened.fulfill() }
        wait(for: [opened], timeout: 15)
        let r = SystemActions.run(.quitApp(url.path), snapshot: nil, apps: [])
        XCTAssertTrue(r.ok, r.message)
        // isTerminated only updates on a spinning main run loop; ask the kernel instead.
        XCTAssertTrue(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit")
            .allSatisfy { kill($0.processIdentifier, 0) != 0 })
    }
}
