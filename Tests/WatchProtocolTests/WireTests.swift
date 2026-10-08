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
        for m in [WSServerMessage.snapshot(sampleSnapshot()), .messages(chatId: "local_1", messages: [msg], reset: true, before: 7, cursor: nil),
                  .messages(chatId: "local_1", messages: [msg], reset: true, before: nil, cursor: "o:12:34"),
                  .job(job), .pong] {
            let back = try roundTrip(m)
            switch (m, back) {
            case (.snapshot, .snapshot), (.job, .job), (.pong, .pong): break
            case (.messages(_, let a, let r1, let c1, let k1), .messages(let id, let b, let r2, let c2, let k2)):
                XCTAssertEqual(id, "local_1"); XCTAssertEqual(a, b); XCTAssertEqual(r1, r2); XCTAssertEqual(c1, c2)
                XCTAssertEqual(k1, k2)
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

    /// Old and new phones and Macs read each other's paging fields.
    func testPagingCursorsStayCompatible() throws {
        // An older Mac's messages / page: no `cursor`, so a newer phone falls back to `before`.
        let oldMac = #"{"type":"messages","chatId":"c","messages":[],"reset":true,"before":12}"#
        guard case .messages(_, _, _, let before, let cursor) = try WireCoder.decoder.decode(WSServerMessage.self, from: Data(oldMac.utf8))
        else { return XCTFail("messages") }
        XCTAssertEqual(before, 12); XCTAssertNil(cursor)
        XCTAssertEqual(OlderCursor(cursor: cursor, before: before), .index(12))
        let page = try WireCoder.decoder.decode(MessagesPage.self, from: Data(#"{"messages":[],"before":3}"#.utf8))
        XCTAssertEqual(page.older, .index(3))
        XCTAssertNil(try WireCoder.decoder.decode(MessagesPage.self, from: Data(#"{"messages":[]}"#.utf8)).older)
        // A newer Mac's page carries the cursor (an older phone ignores it; it never asks for one).
        let newPage = try WireCoder.encoder.encode(MessagesPage(messages: [], before: nil, cursor: "o:5:9"))
        XCTAssertEqual(try WireCoder.decoder.decode(MessagesPage.self, from: newPage).older, .token("o:5:9"))
        // An older phone's subscribe has no `cursors`; a newer one's still decodes (older Macs skip the key).
        XCTAssertNil(try WireCoder.decoder.decode(WSClientMessage.self, from: Data(#"{"type":"subscribe","chatId":"c"}"#.utf8)).cursors)
        let sub = WSClientMessage(type: .subscribe, chatId: "c", cursors: true)
        XCTAssertEqual(try roundTrip(sub), sub)
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

    func testLiveWorkTravelsAndOldPayloadsDecode() throws {
        let w = LiveWork(running: [RunningTool(id: "t1", name: "Bash", summary: "Bash: swift test", startedAt: t)],
                         agents: [AgentRun(id: "a1", description: "Survey", type: "Explore", step: "Read App.swift",
                                           steps: 4, startedAt: t)],
                         shells: [BackgroundShell(id: "b1", summary: "dev server", startedAt: t)])
        guard case .work(let id, let back) = try roundTrip(WSServerMessage.work(chatId: "local_1", work: w)) else {
            return XCTFail("type changed")
        }
        XCTAssertEqual(id, "local_1")
        XCTAssertEqual(back, w)
        XCTAssertEqual(w.line, "1 agent · 1 shell · Bash: swift test")
        XCTAssertNil(LiveWork().line)
        XCTAssertNil(LiveWork().brief)

        var snap = sampleSnapshot()
        snap.accounts[0].sessions[0].work = w.brief
        XCTAssertEqual(try roundTrip(snap).accounts[0].sessions[0].work?.agents.first?.steps, 0, "brief drops steps")
        // A snapshot from a Mac without it.
        XCTAssertNil(try roundTrip(sampleSnapshot()).accounts[0].sessions[0].work)
        XCTAssertEqual(try WireCoder.decoder.decode(LiveWork.self, from: Data("{}".utf8)), LiveWork())
    }
}
