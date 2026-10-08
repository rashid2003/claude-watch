import XCTest
@testable import WatchCore

final class DesktopDraftTests: XCTestCase {
    func shows(urls: [String] = [], window: String? = nil, title: String = "Fix the login bug") -> Bool {
        DesktopDraftReader.shows(chatId: "local_abc123", cliId: "5f0e-cli-id", title: title, urls: urls, windowTitle: window)
    }

    func testURLNamingTheChatWins() {
        XCTAssertTrue(shows(urls: ["app://claude/code/local_abc123"]))
        XCTAssertTrue(shows(urls: ["file:///index.html#/session/5f0e-cli-id"]))
        XCTAssertFalse(shows(urls: ["app://claude/code/local_other"], window: "Fix the login bug"), "the URL names another chat")
    }

    func testFallsBackToTheWindowTitle() {
        XCTAssertTrue(shows(urls: ["app://claude/"], window: "Fix the login bug"))
        XCTAssertTrue(shows(window: "Fix the login bug - Claude"))
        XCTAssertFalse(shows(window: "Claude"))
        XCTAssertFalse(shows(window: nil))
        XCTAssertFalse(shows(window: "Claude", title: "Claude"))
        XCTAssertFalse(shows(window: "ab", title: "ab"), "too short to trust")
    }
}
