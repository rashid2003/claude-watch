import XCTest
@testable import WatchCore

final class NewChatTrustTests: XCTestCase {
    func testTrustedWhenFolderOrParentAccepted() {
        let accepted: Set<String> = ["/Users/me/Development", "/Users/me/Solo"]
        XCTAssertTrue(WorkspaceTrust.isTrusted("/Users/me/Development", accepted: accepted, realPath: nil))
        XCTAssertTrue(WorkspaceTrust.isTrusted("/Users/me/Development/app/", accepted: accepted, realPath: nil))
        XCTAssertTrue(WorkspaceTrust.isTrusted("/Users/me/Solo", accepted: accepted, realPath: nil))
        XCTAssertFalse(WorkspaceTrust.isTrusted("/Users/me/Downloads/x", accepted: accepted, realPath: nil))
        XCTAssertFalse(WorkspaceTrust.isTrusted("/Users/me/Developmental", accepted: accepted, realPath: nil), "a sibling with the same prefix")
        XCTAssertFalse(WorkspaceTrust.isTrusted("relative/path", accepted: accepted, realPath: nil))
    }

    func testResolvedPathCounts() {
        XCTAssertTrue(WorkspaceTrust.isTrusted("/tmp/link", accepted: ["/private/tmp/real"], realPath: "/private/tmp/real/x"))
    }

    func testReadsAcceptedFoldersFromConfig() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("claude-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let json = #"{"projects":{"/a/yes":{"hasTrustDialogAccepted":true},"/a/no":{"hasTrustDialogAccepted":false},"/a/bare":{}}}"#
        try json.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(WorkspaceTrust.acceptedFolders(file: file), ["/a/yes"])
    }

    func testWorktreeLinksOpenTheRepo() {
        XCTAssertEqual(DesktopActions.linkFolder("/Users/me/app/.claude/worktrees/brave-x"), "/Users/me/app")
        XCTAssertEqual(DesktopActions.linkFolder("/Users/me/app/.claude/worktrees/brave-x/sub"), "/Users/me/app")
        XCTAssertEqual(DesktopActions.linkFolder("/Users/me/app/.claude/worktrees"), "/Users/me/app/.claude/worktrees")
        XCTAssertEqual(DesktopActions.linkFolder("/Users/me/app/"), "/Users/me/app")
    }

    func testPromptMustNameTheFolder() {
        XCTAssertTrue(DesktopActions.promptNames("/Users/me/app", ["Trust this workspace?", "/Users/me/app", "Trust workspace"]))
        XCTAssertFalse(DesktopActions.promptNames("/Users/me/app", ["/Users/me/app-evil"]))
        XCTAssertFalse(DesktopActions.promptNames("/Users/me/app", ["/Users/me"]))
        let long = "/Users/me/" + String(repeating: "deep/", count: 70) + "end"
        XCTAssertTrue(DesktopActions.promptNames(long, [String(long.prefix(180)) + "…"]), "a shortened long path")
    }

    func testComposerHoldsThePrompt() {
        XCTAssertTrue(DesktopActions.startsLike("Fix the login bug please", "Fix the login bug please"))
        XCTAssertFalse(DesktopActions.startsLike("", "Fix it"))
        XCTAssertFalse(DesktopActions.startsLike("Something else", "Fix it"))
    }
}
