import XCTest
@testable import WatchCore

final class ProcessScanTests: XCTestCase {
    func p(_ pid: Int32, _ path: String, mb: Int64, ppid: Int32 = 1, cpu: Double = 0) -> (ProcSample, cpu: Double) {
        (ProcSample(pid: pid, ppid: ppid, name: (path as NSString).lastPathComponent, path: path, footprint: mb << 20, cpuNanos: 0), cpu: cpu)
    }

    func testOutermostBundle() {
        XCTAssertEqual(AppGrouper.bundle(of: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"),
                       "/Applications/Google Chrome.app")
        XCTAssertEqual(AppGrouper.bundle(of: "/Applications/Docker.app/Contents/MacOS/com.docker.virtualization"), "/Applications/Docker.app")
        XCTAssertNil(AppGrouper.bundle(of: "/Users/r/Library/Android/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64"))
    }

    func testGroupsHelpersAndKeepsLooseProcesses() {
        let procs = [p(100, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", mb: 300),
                     p(101, "/Applications/Google Chrome.app/Contents/Frameworks/X.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper", mb: 700, ppid: 100),
                     p(200, "/Users/r/Library/Android/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64", mb: 1900),
                     p(300, "/usr/bin/true", mb: 1)]
        let rows = AppGrouper.group(procs, appPid: { $0.hasSuffix("Chrome.app") ? 100 : nil }, appName: { _ in nil },
                                    claudeNames: [:], guardFn: { _ in true }, limit: 2)
        XCTAssertEqual(rows.map(\.name), ["qemu-system-aarch64", "Google Chrome"])
        let chrome = rows[1]
        XCTAssertEqual(chrome.rss, 1000 << 20)
        XCTAssertEqual(chrome.processes, 2)
        XCTAssertEqual(chrome.mainPid, 100)
        XCTAssertTrue(chrome.canQuit)
        XCTAssertEqual(chrome.pids, [101, 100])
        XCTAssertEqual(rows[0].id, "pid:200")
        XCTAssertFalse(rows[0].canQuit)
    }

    func testBusyCPUProcessesAreIncludedEvenWhenSmall() {
        let rows = AppGrouper.group([p(1000, "/a/big", mb: 900), p(1001, "/b/medium", mb: 500), p(1002, "/usr/bin/python3", mb: 20, cpu: 180)],
                                    appPid: { _ in nil }, appName: { _ in nil }, claudeNames: [:], guardFn: { _ in true }, limit: 1)
        XCTAssertEqual(rows.map(\.name), ["big", "python3"])
    }

    func testClaudeProfilesAreSeparateRows() {
        let claude = "/Applications/Claude.app/Contents/MacOS/Claude"
        let helper = "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper"
        let rows = AppGrouper.group([p(10, claude, mb: 200), p(11, helper, mb: 900, ppid: 10),
                                     p(20, claude, mb: 150), p(21, helper, mb: 400, ppid: 20)],
                                    appPid: { _ in 10 }, appName: { _ in "Claude" },
                                    claudeNames: [10: "Hamagan", 20: "Lajward"], guardFn: { _ in true })
        XCTAssertEqual(Set(rows.map(\.name)), ["Claude · Hamagan", "Claude · Lajward"])
        XCTAssertEqual(rows.first { $0.name == "Claude · Hamagan" }?.rss, 1100 << 20)
        XCTAssertEqual(rows.first { $0.name == "Claude · Lajward" }?.id, "claude:20")
    }

    func testKillGuard() {
        let me = getuid()
        XCTAssertTrue(KillGuard.allows(pid: 4411, name: "qemu-system-aarch64", ownerUid: me))
        XCTAssertFalse(KillGuard.allows(pid: 1, name: "launchd", ownerUid: 0))
        XCTAssertFalse(KillGuard.allows(pid: 400, name: "WindowServer", ownerUid: me))
        XCTAssertFalse(KillGuard.allows(pid: 500, name: "python3", ownerUid: me &+ 1))
        XCTAssertFalse(KillGuard.allows(pid: getpid(), name: "x", ownerUid: me))
        XCTAssertFalse(KillGuard.allowsLive(pid: getpid()).ok)
        XCTAssertFalse(KillGuard.allowsLive(pid: 1).ok)
    }
}
