import XCTest
@testable import WatchBridge
import WatchProtocol

final class DraftBookTests: XCTestCase {
    let t = Date(timeIntervalSince1970: 1_790_600_000)

    func testPhoneDraftsSetAndClear() {
        let b = DraftBook(url: nil)
        XCTAssertTrue(b.setPhone(chatId: "a", text: "hello", at: t))
        XCTAssertFalse(b.setPhone(chatId: "a", text: "hello", at: t + 1), "same text is no change")
        XCTAssertEqual(b.draft(chatId: "a"), ChatDraft(text: "hello", source: .phone, at: t))
        XCTAssertTrue(b.setPhone(chatId: "a", text: "", at: t + 2))
        XCTAssertNil(b.draft(chatId: "a"))
        XCTAssertFalse(b.setPhone(chatId: "a", text: "  ", at: t + 3))
    }

    func testDesktopChangesWinAndOnlyChangesCount() {
        let b = DraftBook(url: nil)
        XCTAssertTrue(b.observeDesktop(chatId: "a", text: "draft", at: t))
        XCTAssertFalse(b.observeDesktop(chatId: "a", text: "draft", at: t + 2), "unchanged read")
        XCTAssertTrue(b.setPhone(chatId: "a", text: "phone edit", at: t + 4))
        XCTAssertFalse(b.observeDesktop(chatId: "a", text: "draft", at: t + 6), "an unchanged desktop doesn't undo a newer phone draft")
        XCTAssertEqual(b.draft(chatId: "a")?.source, .phone)
        XCTAssertTrue(b.observeDesktop(chatId: "a", text: "draft 2", at: t + 8))
        XCTAssertEqual(b.draft(chatId: "a"), ChatDraft(text: "draft 2", source: .desktop, at: t + 8))
        XCTAssertFalse(b.setPhone(chatId: "a", text: "", at: t + 9), "clearing the phone leaves the desktop draft")
        XCTAssertTrue(b.observeDesktop(chatId: "a", text: "", at: t + 10), "sent or deleted on the Mac")
        XCTAssertNil(b.draft(chatId: "a"))
    }

    func testFirstDesktopReadDoesNotReplaceAPhoneDraft() {
        let b = DraftBook(url: nil)
        b.setPhone(chatId: "a", text: "from the phone", at: t)
        XCTAssertFalse(b.observeDesktop(chatId: "a", text: "old desktop text", at: t + 60))
        XCTAssertEqual(b.draft(chatId: "a")?.text, "from the phone")
        XCTAssertTrue(b.observeDesktop(chatId: "a", text: "old desktop text, edited", at: t + 62))
        XCTAssertEqual(b.draft(chatId: "a")?.source, .desktop)
    }

    func testPrefilledEchoKeepsTheDesktopSource() {
        let b = DraftBook(url: nil)
        b.observeDesktop(chatId: "a", text: "same", at: t)
        XCTAssertFalse(b.setPhone(chatId: "a", text: "same", at: t + 5))
        XCTAssertEqual(b.draft(chatId: "a"), ChatDraft(text: "same", source: .desktop, at: t))
    }

    func testSendingClearsAndTheDesktopTextStaysSeen() {
        let b = DraftBook(url: nil)
        b.observeDesktop(chatId: "a", text: "left on the Mac", at: t)
        XCTAssertTrue(b.clear(chatId: "a"))
        XCTAssertFalse(b.clear(chatId: "a"))
        XCTAssertFalse(b.observeDesktop(chatId: "a", text: "left on the Mac", at: t + 2), "doesn't come back until it changes")
        b.forgetDesktop(except: [])
        XCTAssertTrue(b.observeDesktop(chatId: "a", text: "left on the Mac", at: t + 4), "watching again starts fresh")
    }

    func testLongTextIsCut() {
        let b = DraftBook(url: nil)
        b.setPhone(chatId: "a", text: String(repeating: "x", count: DraftMerge.maxLength + 10))
        XCTAssertEqual(b.draft(chatId: "a")?.text.count, DraftMerge.maxLength)
    }

    func testPersistenceDropsOldDrafts() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("drafts-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let b = DraftBook(url: url)
        b.setPhone(chatId: "old", text: "stale", at: t - DraftBook.maxAge - 1)
        b.setPhone(chatId: "new", text: "keep", at: t)
        XCTAssertEqual(DraftBook(url: url, now: t).all, ["new": ChatDraft(text: "keep", source: .phone, at: t)])
    }
}
