import CryptoKit
import XCTest
@testable import WatchBridge
import WatchProtocol

final class LiveActivityTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func limits(five: Int = 40, state: AccountState = .working, prompts: Int = 0) -> LiveLimits {
        LiveLimits(accounts: [.init(id: "default", name: "lajward.dev", state: state, five: five, week: 20)],
                   prompts: prompts, updated: t0.timeIntervalSince1970)
    }

    func device(wants: Bool? = true, token: String? = "tok", start: String? = "start", startedAt: Date? = nil) -> Device {
        var d = Device(id: "dev-1", name: "iPhone", tokenHash: "", createdAt: t0)
        d.liveActivity = wants; d.activityToken = token; d.activityStartToken = start; d.activityStartedAt = startedAt ?? t0
        return d
    }

    func testFirstSnapshotSendsAnUpdate() {
        let plan = LiveActivityDriver().plan(for: device(), limits(), macName: "Mac", now: t0)
        XCTAssertEqual(plan.map(\.push.event), [.update])
        XCTAssertEqual(plan.first?.token, "tok")
    }

    func testSmallChangesAreRationed() {
        let d = LiveActivityDriver(), dev = device()
        _ = d.plan(for: dev, limits(five: 40), macName: "Mac", now: t0)
        XCTAssertTrue(d.plan(for: dev, limits(five: 41), macName: "Mac", now: t0 + 30).isEmpty)
        let later = d.plan(for: dev, limits(five: 42), macName: "Mac", now: t0 + 130)
        XCTAssertEqual(later.first?.push.priority, 5)
    }

    func testStateChangesGoOutAtOnce() {
        let d = LiveActivityDriver(), dev = device()
        _ = d.plan(for: dev, limits(), macName: "Mac", now: t0)
        let p = d.plan(for: dev, limits(five: 100, state: .limited), macName: "Mac", now: t0 + 5)
        XCTAssertEqual(p.first?.push.priority, 10)
        XCTAssertEqual(d.plan(for: dev, limits(prompts: 1), macName: "Mac", now: t0 + 6).count, 1)
    }

    func testQuietActivityGetsAHeartbeat() {
        let d = LiveActivityDriver(), dev = device()
        _ = d.plan(for: dev, limits(), macName: "Mac", now: t0)
        XCTAssertTrue(d.plan(for: dev, limits(), macName: "Mac", now: t0 + LiveActivityDriver.heartbeat - 15).isEmpty)
        XCTAssertEqual(d.plan(for: dev, limits(), macName: "Mac", now: t0 + LiveActivityDriver.heartbeat + 1).count, 1)
    }

    func testHeartbeatKeepsAQuietActivityFreshWithinBudget() {
        let d = LiveActivityDriver(), dev = device()
        var sends: [ActivityPush] = []
        // An hour of unchanged snapshots at the Mac's 15 s poll.
        for i in 0...240 {
            sends += d.plan(for: dev, limits(), macName: "Mac", now: t0 + Double(i) * 15).map(\.push)
        }
        XCTAssertEqual(sends.count, 13, "the first update, then one every 5 minutes")
        XCTAssertTrue(sends.dropFirst().allSatisfy { $0.priority == 5 }, "heartbeats don't spend the push budget")
        // Each push's stale date lands after the next one arrives, with room for one to go missing.
        for (a, b) in zip(sends, sends.dropFirst()) {
            XCTAssertGreaterThan(a.staleDate!.timeIntervalSince(b.now), LiveActivityDriver.heartbeat)
        }
        XCTAssertGreaterThan(ActivityPush.staleAfter, 2 * LiveActivityDriver.heartbeat)
    }

    func testEveryPushCarriesAStaleDate() throws {
        func aps(_ e: ActivityPush.Event) throws -> [String: Any] {
            let push = ActivityPush(event: e, state: limits(), macName: "Mac", important: false, now: t0)
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: push.payload()) as? [String: Any])
            return try XCTUnwrap(obj["aps"] as? [String: Any])
        }
        let expected = Int(t0.timeIntervalSince1970 + ActivityPush.staleAfter)
        XCTAssertEqual(try aps(.start)["stale-date"] as? Int, expected)
        XCTAssertEqual(try aps(.update)["stale-date"] as? Int, expected)
        XCTAssertNil(try aps(.end)["stale-date"])
        XCTAssertEqual(ActivityPush.staleAfter, 12 * 60)
    }

    func testMacPushesLeaveConnectedOutAndOldContentDecodes() throws {
        let push = ActivityPush(event: .update, state: limits(), macName: "Mac", important: false, now: t0)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: push.payload()) as? [String: Any])
        let content = try XCTUnwrap((obj["aps"] as? [String: Any])?["content-state"] as? [String: Any])
        XCTAssertNil(content["connected"], "a push from the Mac clears the phone's offline mark")
        let old = #"{"accounts":[],"hidden":0,"prompts":0,"working":0,"updated":1800000000}"#
        let back = try JSONDecoder().decode(LiveLimits.self, from: Data(old.utf8))
        XCTAssertNil(back.connected)
        XCTAssertFalse(back.disconnected)
        var marked = limits()
        marked.connected = false
        XCTAssertTrue(try JSONDecoder().decode(LiveLimits.self, from: JSONEncoder().encode(marked)).disconnected)
    }

    // MARK: Going offline

    func content(_ push: ActivityPush) throws -> (aps: [String: Any], content: [String: Any]) {
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: push.payload()) as? [String: Any])
        let aps = try XCTUnwrap(obj["aps"] as? [String: Any])
        return (aps, try XCTUnwrap(aps["content-state"] as? [String: Any]))
    }

    func testOfflinePushIsUrgentStaleAtOnceAndMarked() throws {
        let push = ActivityPush.offline(limits(), reason: LiveLimits.Offline.sleep, macName: "Mac", now: t0)
        XCTAssertEqual(push.event, .update)
        XCTAssertEqual(push.priority, 10)
        let (aps, content) = try content(push)
        XCTAssertEqual(aps["event"] as? String, "update")
        XCTAssertEqual(aps["stale-date"] as? Int, Int(t0.timeIntervalSince1970), "old widgets show offline via isStale")
        XCTAssertEqual(aps["timestamp"] as? Int, Int(t0.timeIntervalSince1970))
        XCTAssertEqual(content["offline"] as? String, "sleep")
        XCTAssertEqual(content["connected"] as? Bool, false, "old widgets show offline via connected")
        XCTAssertEqual(content["updated"] as? Double, t0.timeIntervalSince1970, "last seen stays the snapshot's time")
        XCTAssertLessThan(push.payload().count, 4096)
    }

    func testOfflineFlagDecodesInTheContentState() throws {
        let push = ActivityPush.offline(limits(), reason: LiveLimits.Offline.quit, macName: "Mac", now: t0)
        let state = try JSONDecoder().decode(LiveLimits.self, from: JSONSerialization.data(withJSONObject: content(push).content))
        XCTAssertEqual(state.offline, "quit")
        XCTAssertTrue(state.disconnected)
        XCTAssertEqual(state.accounts, limits().accounts)
        // A reason this build doesn't know still decodes, and still reads as offline.
        var future = try content(push).content
        future["offline"] = "restart"
        XCTAssertTrue(try JSONDecoder().decode(LiveLimits.self, from: JSONSerialization.data(withJSONObject: future)).disconnected)
        // Ordinary pushes leave it out.
        let normal = ActivityPush(event: .update, state: limits(), macName: "Mac", important: true, now: t0)
        XCTAssertNil(try content(normal).content["offline"])
    }

    func testGoingOfflineTellsRunningActivitiesThenHoldsUntilWake() {
        let d = LiveActivityDriver()
        var off = device()
        off.id = "dev-off"
        off.liveActivity = false
        var noToken = device(token: nil)
        noToken.id = "dev-2"
        _ = d.plan(for: device(), limits(), macName: "Mac", now: t0)
        let sends = d.goingOffline([device(), off, noToken], limits(five: 50), reason: "sleep", macName: "Mac", now: t0 + 60)
        XCTAssertEqual(sends.map(\.deviceId), ["dev-1"])
        XCTAssertEqual(sends.first?.token, "tok")
        XCTAssertEqual(sends.first?.push.state.offline, "sleep")
        XCTAssertEqual(sends.first?.push.state.accounts.first?.five, 50)
        XCTAssertTrue(d.isSuspended)
        // Snapshots on the way down (or in a dark wake) don't undo it, not even a heartbeat or a state change.
        XCTAssertTrue(d.plan(for: device(), limits(five: 100, state: .limited), macName: "Mac", now: t0 + 61).isEmpty)
        XCTAssertTrue(d.plan(for: device(), limits(), macName: "Mac", now: t0 + 3600).isEmpty)
        // Awake: the very next snapshot goes out at once, urgent and online.
        d.resume()
        XCTAssertFalse(d.isSuspended)
        let back = d.plan(for: device(), limits(five: 50), macName: "Mac", now: t0 + 3601)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back.first?.push.priority, 10)
        XCTAssertNil(back.first?.push.state.offline)
        XCTAssertNil(back.first?.push.state.connected)
        XCTAssertEqual(back.first?.push.staleDate, t0 + 3601 + ActivityPush.staleAfter)
    }

    func testPusherWithoutAKeySendsNothingAndSaysSo() {
        let p = Pusher(key: nil)
        let push = ActivityPush.offline(limits(), reason: "quit", macName: "Mac", now: t0)
        XCTAssertNil(p.request(push, token: "tok", environment: nil))
        let got = expectation(description: "done")
        p.send(push, token: "tok", environment: nil, gone: {}, done: { status in
            XCTAssertEqual(status, 0)
            got.fulfill()
        })
        wait(for: [got], timeout: 1)
    }

    func testOfflineRequestIsAnUrgentLiveActivityPush() throws {
        let key = APNsKey(keyId: "ABC123DEFG", teamId: "TEAM123456", pem: P256.Signing.PrivateKey().pemRepresentation, topic: "dev.x")
        let push = ActivityPush.offline(limits(), reason: "sleep", macName: "Mac", now: t0)
        let r = try XCTUnwrap(Pusher(key: key).request(push, token: "tok", environment: "sandbox"))
        XCTAssertEqual(r.url?.absoluteString, "https://api.sandbox.push.apple.com/3/device/tok")
        XCTAssertEqual(r.value(forHTTPHeaderField: "apns-priority"), "10")
        XCTAssertEqual(r.value(forHTTPHeaderField: "apns-push-type"), "liveactivity")
        XCTAssertEqual(r.value(forHTTPHeaderField: "apns-topic"), "dev.x.push-type.liveactivity")
        XCTAssertEqual(r.httpBody, push.payload())
    }

    func testStartsRemotelyWhenWantedWithoutAnActivity() {
        let d = LiveActivityDriver(), dev = device(token: nil)
        XCTAssertEqual(d.plan(for: dev, limits(), macName: "Mac", now: t0).map(\.push.event), [.start])
        XCTAssertTrue(d.plan(for: dev, limits(), macName: "Mac", now: t0 + 60).isEmpty, "start is retried only every 10 min")
    }

    func testDoesNotStartRemotelyWhileTheAppIsOpen() {
        var dev = device(token: nil)
        dev.lastSeenAt = t0 - 20
        XCTAssertTrue(LiveActivityDriver().plan(for: dev, limits(), macName: "Mac", now: t0).isEmpty)
    }

    func testRollsOverBeforeTheEightHourCap() {
        let dev = device(startedAt: t0)
        let plan = LiveActivityDriver().plan(for: dev, limits(), macName: "Mac", now: t0 + 8 * 3600)
        XCTAssertEqual(plan.map(\.push.event), [.end, .start])
        XCTAssertEqual(plan.map(\.token), ["tok", "start"])
    }

    func testTurnedOffEndsIt() {
        XCTAssertEqual(LiveActivityDriver().plan(for: device(wants: false), limits(), macName: "Mac", now: t0).map(\.push.event), [.end])
        XCTAssertTrue(LiveActivityDriver().plan(for: device(wants: false, token: nil), limits(), macName: "Mac", now: t0).isEmpty)
    }

    func testPayloadShape() throws {
        let push = ActivityPush(event: .start, state: limits(), macName: "Mac", important: true, now: t0)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: push.payload()) as? [String: Any])
        let aps = try XCTUnwrap(obj["aps"] as? [String: Any])
        XCTAssertEqual(aps["event"] as? String, "start")
        XCTAssertEqual(aps["attributes-type"] as? String, "LimitsActivityAttributes")
        XCTAssertEqual((aps["attributes"] as? [String: String])?["macName"], "Mac")
        XCTAssertNotNil(aps["alert"])
        let content = try XCTUnwrap(aps["content-state"] as? [String: Any])
        let back = try JSONDecoder().decode(LiveLimits.self, from: JSONSerialization.data(withJSONObject: content))
        XCTAssertEqual(back, limits())
        XCTAssertLessThan(push.payload().count, 4096)
    }

    func testFourBusyAccountsFitInAPush() {
        let accounts = (0..<LiveLimits.maxAccounts).map {
            LiveLimits.Account(id: "account-\($0)", name: "some-long-domain-name-\($0).example.com", org: "An Organisation Name",
                               state: .limited, five: 100, week: 99, fiveResets: 1_800_000_000, weekResets: 1_800_000_000,
                               limitedUntil: 1_800_000_000, working: 3)
        }
        let push = ActivityPush(event: .start, state: LiveLimits(accounts: accounts, hidden: 3, prompts: 9, working: 9,
                                                                updated: 1_800_000_000), macName: "Rashid's MacBook Pro",
                                important: true, now: t0)
        XCTAssertLessThan(push.payload().count, 4096)
    }

    func testImportanceThresholds() {
        XCTAssertFalse(LiveActivityDriver.isImportant(from: limits(five: 40), to: limits(five: 45)))
        XCTAssertTrue(LiveActivityDriver.isImportant(from: limits(five: 88), to: limits(five: 91)))
        XCTAssertTrue(LiveActivityDriver.isImportant(from: limits(five: 70), to: limits(five: 2)), "a reset")
    }

    func testSplitName() {
        XCTAssertEqual(LiveLimits.split("rashid@lajward.dev (Hamagan)").title, "lajward.dev")
        XCTAssertEqual(LiveLimits.split("rashid@lajward.dev (Hamagan)").org, "Hamagan")
        XCTAssertEqual(LiveLimits.split("Work").title, "Work")
    }
}
