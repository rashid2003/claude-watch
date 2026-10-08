import CryptoKit
import XCTest
@testable import WatchBridge
import WatchProtocol

final class PusherTests: XCTestCase {
    func decode(_ s: Substring) -> Data {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)!
    }

    func testJWTIsSignedES256() throws {
        let priv = P256.Signing.PrivateKey()
        let pusher = Pusher(key: APNsKey(keyId: "ABC123DEFG", teamId: "TEAM123456", pem: priv.pemRepresentation, topic: "dev.x"))
        let now = Date(timeIntervalSince1970: 1_790_600_000)
        let jwt = try pusher.jwt(now: now)
        let parts = jwt.split(separator: ".")
        XCTAssertEqual(parts.count, 3)
        let header = try JSONSerialization.jsonObject(with: decode(parts[0])) as! [String: Any]
        XCTAssertEqual(header["alg"] as? String, "ES256")
        XCTAssertEqual(header["kid"] as? String, "ABC123DEFG")
        let claims = try JSONSerialization.jsonObject(with: decode(parts[1])) as! [String: Any]
        XCTAssertEqual(claims["iss"] as? String, "TEAM123456")
        XCTAssertEqual(claims["iat"] as? Int, 1_790_600_000)
        let sig = try P256.Signing.ECDSASignature(rawRepresentation: decode(parts[2]))
        XCTAssertTrue(priv.publicKey.isValidSignature(sig, for: Data((parts[0] + "." + parts[1]).utf8)))
        XCTAssertEqual(try pusher.jwt(now: now.addingTimeInterval(60)), jwt, "cached")
        XCTAssertNotEqual(try pusher.jwt(now: now.addingTimeInterval(3600)), jwt, "refreshed")
    }

    func testPayload() throws {
        let n = PushNote(category: "PROMPT", title: "Work · claude-watch", body: "swift build", threadId: "local_1",
                         collapseId: "prompt-local_1", userInfo: ["chatId": "local_1", "promptId": "p1"])
        let obj = try JSONSerialization.jsonObject(with: n.payload()) as! [String: Any]
        let aps = obj["aps"] as! [String: Any]
        XCTAssertEqual(aps["category"] as? String, "PROMPT")
        XCTAssertEqual((aps["alert"] as? [String: String])?["body"], "swift build")
        XCTAssertEqual(obj["promptId"] as? String, "p1")
    }

    func prompt(_ tool: String, always: Bool, kind: PendingPrompt.Kind = .permission) -> PendingPrompt {
        PendingPrompt(id: "p1", chatId: "local_1", profileId: "account-1", chatTitle: "Fix bug", toolName: tool,
                      summary: "swift build", source: .desktop, kind: kind, at: Date(), canAllowAlways: always)
    }

    func testPromptNoteCarriesIdsAndCategory() throws {
        let n = PushNote.prompt(prompt("Edit", always: true), account: "Work")
        let obj = try JSONSerialization.jsonObject(with: n.payload()) as! [String: Any]
        XCTAssertEqual((obj["aps"] as? [String: Any])?["category"] as? String, "PROMPT_ALWAYS")
        XCTAssertEqual(obj["chatId"] as? String, "local_1")
        XCTAssertEqual(obj["promptId"] as? String, "p1")
        XCTAssertEqual(obj["profileId"] as? String, "account-1")
        XCTAssertEqual(n.title, "Work · Fix bug")
        XCTAssertEqual(n.body, "Edit: swift build")
        XCTAssertEqual(n.threadId, "local_1")
        XCTAssertEqual(n.collapseId, "prompt-local_1")
    }

    func testPromptCategories() {
        XCTAssertEqual(PushNote.prompt(prompt("Edit", always: false), account: "W").category, PushCategory.prompt)
        XCTAssertEqual(PushNote.prompt(prompt("Edit", always: true), account: "W").category, PushCategory.promptAlways)
        XCTAssertEqual(PushNote.prompt(prompt("Bash", always: false), account: "W").category, PushCategory.promptShell)
        XCTAssertEqual(PushNote.prompt(prompt("Bash", always: true), account: "W").category, PushCategory.promptShellAlways)
        let q = PushNote.prompt(prompt("AskUserQuestion", always: false, kind: .question), account: "W")
        XCTAssertEqual(q.category, PushCategory.chat, "questions are answered on the Mac")
        XCTAssertEqual(q.body, "swift build")
    }
}
