import XCTest
@testable import WatchProtocol

final class DraftTests: XCTestCase {
    let t = Date(timeIntervalSince1970: 1_790_600_000)

    func desktop(_ text: String, _ dt: TimeInterval = 0) -> ChatDraft { ChatDraft(text: text, source: .desktop, at: t + dt) }

    func testSnapshotCarriesDraftsAndOlderSnapshotsDecode() throws {
        var s = Snapshot(at: t, accounts: [], queue: [], engineOwner: true, scanning: false)
        s.drafts = ["local_1": desktop("half a thought")]
        let back = try WireCoder.decoder.decode(Snapshot.self, from: WireCoder.encoder.encode(s))
        XCTAssertEqual(back.drafts, s.drafts)

        let old = #"{"at":1790600000,"accounts":[],"queue":[],"engineOwner":false,"scanning":false}"#
        XCTAssertTrue(try WireCoder.decoder.decode(Snapshot.self, from: Data(old.utf8)).drafts.isEmpty)
        let bad = #"{"at":1790600000,"accounts":[],"queue":[],"engineOwner":false,"scanning":false,"drafts":{"x":{"text":1}}}"#
        XCTAssertTrue(try WireCoder.decoder.decode(Snapshot.self, from: Data(bad.utf8)).drafts.isEmpty, "a bad draft doesn't sink the snapshot")
    }

    func testEmptyComposerTakesANewerDesktopDraft() {
        XCTAssertEqual(DraftMerge.composer(local: "", prefilled: nil, localAt: nil, remote: desktop("hi")), "hi")
        XCTAssertEqual(DraftMerge.composer(local: "  ", prefilled: nil, localAt: t - 60, remote: desktop("hi")), "hi")
        XCTAssertNil(DraftMerge.composer(local: "", prefilled: nil, localAt: t + 5, remote: desktop("hi")),
                     "cleared on the phone after the desktop draft was typed")
    }

    func testTypedTextIsNeverReplaced() {
        XCTAssertNil(DraftMerge.composer(local: "mine", prefilled: nil, localAt: t - 600, remote: desktop("theirs")))
        XCTAssertNil(DraftMerge.composer(local: "hi there", prefilled: "hi", localAt: t + 1, remote: desktop("hi again", 9)),
                     "an edited prefill is the user's")
    }

    func testPhoneDraftsAreIgnored() {
        XCTAssertNil(DraftMerge.composer(local: "", prefilled: nil, localAt: nil, remote: ChatDraft(text: "echo", source: .phone, at: t)))
    }

    func testUntouchedPrefillFollowsTheDesktop() {
        XCTAssertEqual(DraftMerge.composer(local: "hi", prefilled: "hi", localAt: t + 30, remote: desktop("hi there", 10)), "hi there")
        XCTAssertNil(DraftMerge.composer(local: "hi", prefilled: "hi", localAt: nil, remote: desktop("hi")))
        XCTAssertEqual(DraftMerge.composer(local: "hi", prefilled: "hi", localAt: nil, remote: nil), "", "sent or deleted on the Mac")
        XCTAssertEqual(DraftMerge.composer(local: "hi", prefilled: "hi", localAt: nil, remote: desktop(" ")), "")
        XCTAssertNil(DraftMerge.composer(local: "", prefilled: nil, localAt: nil, remote: nil))
    }
}
