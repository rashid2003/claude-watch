import XCTest
@testable import WatchProtocol

final class WireTests: XCTestCase {
    let t = Date(timeIntervalSince1970: 1_790_600_000)

    func roundTrip<T: Codable>(_ v: T) throws -> T {
        try WireCoder.decoder.decode(T.self, from: WireCoder.encoder.encode(v))
    }

    func sampleSnapshot() -> Snapshot {
        let p = Profile(id: "account-1", name: "Work", dataDir: URL(fileURLWithPath: "/tmp/p1"))
        let info = SessionInfo(id: "local_1", cliSessionId: "c1", priorCliSessionIds: [], profileId: p.id,
                               accountUuid: "a/o", title: "Fix bug", cwd: "/tmp/x", model: nil, permissionMode: "default",
                               lastActivityAt: t, isArchived: false, desktopError: nil, desktopErrorAt: nil,
                               hasPendingPermission: false)
        let s = SessionStatus(info: info, activity: .working, tail: TranscriptTail(last: .assistantTool, lastAt: t),
                              tasks: [TaskItem(id: "1", subject: "Write tests", status: .in_progress)], tokens5h: 10, tokens7d: 20)
        let a = AccountStatus(profile: p, memberProfileIds: [p.id], alsoOpenIn: [], accountUuid: "a/o", running: true,
                              pid: 42, state: .working, limitedUntil: nil, limitKind: nil,
                              fiveHour: LimitForecast(percent: 62), weekly: LimitForecast(percent: 28, resetsFirst: true),
                              tokens5h: 1, tokens7d: 2, tokensPerHourNow: 3, sessions: [s], retryMode: .ui)
        let prompt = PendingPrompt(id: "p1", chatId: "local_1", profileId: p.id, chatTitle: "Fix bug", toolName: "Bash",
                                   summary: "swift build", source: .desktop, at: t)
        return Snapshot(at: t, accounts: [a], queue: [], engineOwner: true, scanning: false, profiles: [p], prompts: [prompt])
    }

    func testSnapshotRoundTrip() throws {
        let s = try roundTrip(sampleSnapshot())
        XCTAssertEqual(s.accounts.first?.sessions.first?.info.title, "Fix bug")
        XCTAssertEqual(s.prompts.first?.summary, "swift build")
        XCTAssertEqual(s.at, t)
    }

    func testSnapshotWithoutNewerKeysDecodes() throws {
        let json = #"{"at":1790600000,"accounts":[],"queue":[],"engineOwner":false,"scanning":false}"#
        let s = try WireCoder.decoder.decode(Snapshot.self, from: Data(json.utf8))
        XCTAssertTrue(s.prompts.isEmpty)
        XCTAssertTrue(s.moves.isEmpty)
    }

    func testServerMessages() throws {
        let job = Job(id: "j1", requestId: "r1", command: "reply", target: "local_1", status: .done, at: t)
        let msg = ChatMessage(id: "u1", kind: .tool, at: t, text: "Ran swift build", toolName: "Bash", toolOK: true)
        for m in [WSServerMessage.snapshot(sampleSnapshot()), .messages(chatId: "local_1", messages: [msg], reset: true, before: 7),
                  .job(job), .pong] {
            let back = try roundTrip(m)
            switch (m, back) {
            case (.snapshot, .snapshot), (.job, .job), (.pong, .pong): break
            case (.messages(_, let a, let r1, let c1), .messages(let id, let b, let r2, let c2)):
                XCTAssertEqual(id, "local_1"); XCTAssertEqual(a, b); XCTAssertEqual(r1, r2); XCTAssertEqual(c1, c2)
            default: XCTFail("type changed: \(m) -> \(back)")
            }
        }
    }

    /// The exact shape the iPhone app parses; changing it breaks installed apps.
    func testGoldenJobMessage() throws {
        let json = #"{"job":{"at":1790600000,"command":"stop","id":"j9","reason":"No such chat","requestId":"r9","status":"failed","target":"local_9"},"type":"job"}"#
        guard case .job(let j) = try WireCoder.decoder.decode(WSServerMessage.self, from: Data(json.utf8)) else {
            return XCTFail("not a job")
        }
        XCTAssertEqual(j.status, .failed)
        XCTAssertEqual(j.reason, "No such chat")
        XCTAssertEqual(String(decoding: try WireCoder.encoder.encode(WSServerMessage.job(j)), as: UTF8.self), json)
    }

    func testClientMessageAndPairing() throws {
        XCTAssertEqual(try roundTrip(WSClientMessage(type: .subscribe, chatId: "local_1")),
                       WSClientMessage(type: .subscribe, chatId: "local_1"))
        let p = PairingPayload(macName: "Mac", hosts: ["mac.tail1.ts.net", "100.64.0.2"], port: 7433, code: "123456")
        XCTAssertEqual(try roundTrip(p), p)
    }

    func testStatusCarriesRelayAndOldStatusDecodes() throws {
        let info = RelayInfo(url: "wss://relay.example", macId: String(repeating: "a", count: 26), macKey: "a2V5")
        let s = BridgeStatus(macName: "Mac", version: "1", warnings: [], pushConfigured: true, relay: info)
        XCTAssertEqual(try WireCoder.decoder.decode(BridgeStatus.self, from: WireCoder.encoder.encode(s)).relay, info)
        let old = #"{"macName":"Mac","version":"1","warnings":[],"pushConfigured":false,"notify":{}}"#
        XCTAssertNil(try WireCoder.decoder.decode(BridgeStatus.self, from: Data(old.utf8)).relay)
    }
}
