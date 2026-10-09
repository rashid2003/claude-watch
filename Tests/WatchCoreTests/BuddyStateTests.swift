import XCTest
import WatchProtocol
@testable import WatchCore

final class BuddyStateTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let profile = Profile(id: "default", name: "Main", dataDir: URL(fileURLWithPath: "/tmp/x"), launcherApp: nil)

    func chat(_ id: String, _ activity: SessionStatus.Activity, last: TranscriptTail.Last = .none,
              permission: Bool = false, age: TimeInterval = 10, profileId: String = "default") -> SessionStatus {
        let info = SessionInfo(id: id, cliSessionId: nil, priorCliSessionIds: [], profileId: profileId, accountUuid: "a",
                               title: "Chat \(id)", cwd: "/tmp", model: nil, permissionMode: nil,
                               lastActivityAt: now.addingTimeInterval(-age), isArchived: false, desktopError: nil,
                               desktopErrorAt: nil, hasPendingPermission: permission)
        return SessionStatus(info: info, activity: activity, tail: TranscriptTail(last: last), tasks: [], tokens5h: 0, tokens7d: 0)
    }

    func snap(_ sessions: [SessionStatus], prompts: [PendingPrompt] = []) -> Snapshot {
        let a = AccountStatus(profile: profile, memberProfileIds: ["default"], alsoOpenIn: [], accountUuid: "a", running: true,
                              pid: nil, state: .working, limitedUntil: nil, limitKind: nil,
                              fiveHour: LimitForecast(percent: 1), weekly: LimitForecast(percent: 1), tokens5h: 0, tokens7d: 0,
                              tokensPerHourNow: 0, sessions: sessions, retryMode: .off)
        return Snapshot(at: now, accounts: [a], queue: [], engineOwner: true, scanning: false, prompts: prompts)
    }

    func testNothingRunningSleeps() {
        var t = BuddyTracker()
        XCTAssertEqual(t.update(snap([chat("a", .idle)]), now: now).mood, .sleeping)
        XCTAssertEqual(t.update(nil, now: now).mood, .sleeping)
    }

    func testWorkingIsBusy() {
        var t = BuddyTracker()
        let s = t.update(snap([chat("a", .working), chat("b", .idle)]), now: now)
        XCTAssertEqual(s.mood, .busy)
        XCTAssertEqual(s.working.map(\.id), ["a"])
    }

    func testNeedsYouBeatsEverything() {
        var t = BuddyTracker()
        let s = t.update(snap([chat("w", .working), chat("e", .failed), chat("p", .idle, permission: true)]), now: now)
        XCTAssertEqual(s.mood, .needsYou)
        XCTAssertEqual(s.urgent?.id, "p")
    }

    func testWaitingActivityNeedsYou() {
        var t = BuddyTracker()
        XCTAssertEqual(t.update(snap([chat("a", .waiting)]), now: now).mood, .needsYou)
    }

    func testPromptNeedsYouAndKeepsTerminalFlag() {
        var t = BuddyTracker()
        let p = PendingPrompt(id: "p1", chatId: "t", profileId: "terminal", chatTitle: "T", toolName: "Bash",
                              summary: "swift build", source: .desktop, at: now)
        let s = t.update(snap([chat("t", .working, profileId: "terminal")], prompts: [p]), now: now)
        XCTAssertEqual(s.mood, .needsYou)
        XCTAssertEqual(s.urgent?.isTerminal, true)
        XCTAssertEqual(s.urgent?.reason, "swift build")
    }

    func testErrorBeatsWorkingButOldErrorIsIgnored() {
        var t = BuddyTracker()
        XCTAssertEqual(t.update(snap([chat("w", .working), chat("e", .failed)]), now: now).mood, .error)
        var t2 = BuddyTracker()
        XCTAssertEqual(t2.update(snap([chat("e", .failed, age: 3 * 3600)]), now: now).mood, .sleeping)
    }

    func testFinishingCelebratesThenSleeps() {
        var t = BuddyTracker()
        _ = t.update(snap([chat("a", .working)]), now: now)
        let done = t.update(snap([chat("a", .idle)]), now: now.addingTimeInterval(1))
        XCTAssertEqual(done.mood, .celebrating)
        XCTAssertEqual(done.urgent?.id, "a")
        let later = t.update(snap([chat("a", .idle)]), now: now.addingTimeInterval(1 + BuddyTracker.celebrationSeconds + 1))
        XCTAssertEqual(later.mood, .sleeping)
    }

    func testNoCelebrationOnFirstSnapshotOrArchived() {
        var t = BuddyTracker()
        XCTAssertEqual(t.update(snap([chat("a", .idle)]), now: now).mood, .sleeping)
    }
}
