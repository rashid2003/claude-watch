import XCTest
@testable import WatchCore

final class TerminalInjectorTests: XCTestCase {
    func testPaneMatchedByTTY() {
        let listing = "/dev/ttys001 %0\n/dev/ttys002 %3\n"
        XCTAssertEqual(TerminalInjector.pane(in: listing, tty: "/dev/ttys002"), "%3")
        XCTAssertNil(TerminalInjector.pane(in: listing, tty: "/dev/ttys009"))
    }

    func testSanitizeStripsEscapesAndNormalisesNewlines() {
        XCTAssertEqual(TerminalInjector.sanitize("  a\u{1B}[201~b\r\nc\r "), "a[201~b\nc")
    }

    func testTTYFromPs() {
        let ok = TerminalInjector(exec: { _, _ in (0, "ttys004\n") }, tmuxPath: nil, appRunning: { _ in false })
        XCTAssertEqual(ok.tty(pid: 1), "/dev/ttys004")
        let none = TerminalInjector(exec: { _, _ in (0, "??\n") }, tmuxPath: nil, appRunning: { _ in false })
        XCTAssertNil(none.tty(pid: 1))
    }

    func testTmuxPanePasteThenEnter() throws {
        let calls = Box()
        let inj = TerminalInjector(exec: { _, a in
            calls.add(a)
            return a.first == "list-panes" ? (0, "/dev/ttys004 %7\n") : (0, "")
        }, tmuxPath: "/usr/bin/tmux", appRunning: { _ in false })
        XCTAssertEqual(inj.tmuxPane(tty: "/dev/ttys004"), "%7")
        let dir = try fixtureDir(pid: 4242, session: "s1")
        let s = session("s1")
        // pid 4242 isn't alive, so entry lookup fails cleanly instead of typing anywhere.
        if case .success = inj.send("hi", session: s, dataDir: dir) { XCTFail("dead pid must not type") }
    }

    func testScriptsMatchByTTYAndPasteBracketed() {
        for app in [TerminalInjector.iTerm, TerminalInjector.terminalApp] {
            let s = TerminalInjector.script(app: app)
            XCTAssertTrue(s.contains("tty of"))
            XCTAssertTrue(s.contains("[200~") && s.contains("[201~"))
        }
    }

    func testEntryFindsLiveInteractiveSession() throws {
        let dir = try fixtureDir(pid: 4242, session: "s1")
        XCTAssertEqual(TerminalInjector.entry(for: session("s1"), in: dir, isAlive: { _ in true })?.pid, 4242)
        XCTAssertNil(TerminalInjector.entry(for: session("s1"), in: dir, isAlive: { _ in false }))
        XCTAssertNil(TerminalInjector.entry(for: session("other"), in: dir, isAlive: { _ in true }))
    }

    // MARK: helpers
    final class Box: @unchecked Sendable {
        private let l = NSLock(); private var v: [[String]] = []
        func add(_ a: [String]) { l.withLock { v.append(a) } }
    }

    func session(_ id: String) -> SessionInfo {
        SessionInfo(id: id, cliSessionId: id, priorCliSessionIds: [], profileId: Profile.terminalId, accountUuid: "a",
                    title: "T", cwd: "/tmp", model: nil, permissionMode: nil, lastActivityAt: Date(), isArchived: false,
                    desktopError: nil, desktopErrorAt: nil, hasPendingPermission: false)
    }

    func fixtureDir(pid: Int, session: String) throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ti-\(UUID().uuidString)")
        let reg = d.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: reg, withIntermediateDirectories: true)
        try #"{"pid":\#(pid),"sessionId":"\#(session)","cwd":"/tmp","kind":"interactive","entrypoint":"cli"}"#
            .write(to: reg.appendingPathComponent("\(pid).json"), atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }
}
