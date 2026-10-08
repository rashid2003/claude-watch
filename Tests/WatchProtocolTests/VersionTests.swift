import XCTest
@testable import WatchProtocol

final class VersionTests: XCTestCase {
    func testHintPointsAtTheOlderSide() {
        XCTAssertNil(WireProtocol.hint(phone: 2, mac: 2))
        XCTAssertEqual(WireProtocol.hint(phone: 1, mac: 2), .updatePhone)
        XCTAssertEqual(WireProtocol.hint(phone: 3, mac: 2), .updateMac)
        // Saying nothing means protocol 1: an old phone against this Mac, this phone against an old Mac.
        XCTAssertEqual(WireProtocol.hint(phone: nil, mac: WireProtocol.current), .updatePhone)
        XCTAssertEqual(WireProtocol.hint(phone: WireProtocol.current, mac: nil), .updateMac)
        XCTAssertNil(WireProtocol.hint(phone: nil, mac: nil))
    }

    func testClientInfoHeadersRoundTripInAnyCase() throws {
        let info = ClientInfo(appVersion: "1.3", build: "202610080636")
        XCTAssertEqual(info.protocolVersion, WireProtocol.current)
        // The Mac's HTTP parser lowercases header names.
        let lower = Dictionary(uniqueKeysWithValues: info.headers.map { ($0.key.lowercased(), $0.value) })
        XCTAssertEqual(ClientInfo(headers: lower), info)
        XCTAssertEqual(ClientInfo(headers: info.headers), info)
        XCTAssertEqual(info.label, "1.3 (202610080636)")
        XCTAssertNil(info.hint())
    }

    func testOldPhonesSendNoClientInfo() {
        XCTAssertNil(ClientInfo(headers: ["authorization": "Bearer x", "content-type": "application/json"]))
        let partial = ClientInfo(headers: ["x-session-watch-protocol": "1"])
        XCTAssertEqual(partial?.protocolVersion, 1)
        XCTAssertEqual(partial?.hint(macProtocol: 2), .updatePhone)
        XCTAssertEqual(ClientInfo(headers: ["x-session-watch-protocol": "junk", "x-session-watch-version": "1.0"])?.protocolVersion, nil)
    }

    func testBridgeStatusFromAnOlderMacStillDecodes() throws {
        let old = #"{"macName":"Mac","version":"0.4.0","warnings":[],"pushConfigured":true,"notify":{}}"#
        let s = try WireCoder.decoder.decode(BridgeStatus.self, from: Data(old.utf8))
        XCTAssertNil(s.protocolVersion)
        XCTAssertEqual(s.hint(), .updateMac)
        let now = BridgeStatus(macName: "Mac", version: "0.5.0", warnings: [], pushConfigured: true)
        let back = try WireCoder.decoder.decode(BridgeStatus.self, from: WireCoder.encoder.encode(now))
        XCTAssertEqual(back.protocolVersion, WireProtocol.current)
        XCTAssertNil(back.hint())
        XCTAssertEqual(back.hint(phoneProtocol: 1), .updatePhone)
    }

    func testLiveLimitsOfflineIsOptional() throws {
        let old = #"{"accounts":[],"hidden":0,"prompts":0,"working":0,"updated":1800000000}"#
        let l = try JSONDecoder().decode(LiveLimits.self, from: Data(old.utf8))
        XCTAssertNil(l.offline)
        XCTAssertFalse(l.disconnected)
        let gone = l.goingOffline(LiveLimits.Offline.sleep)
        XCTAssertEqual(gone.connected, false)
        XCTAssertTrue(gone.disconnected)
        XCTAssertEqual(try JSONDecoder().decode(LiveLimits.self, from: JSONEncoder().encode(gone)), gone)
        // Encoded without the field, it stays out of the JSON (older widget builds never see it).
        let json = String(decoding: try JSONEncoder().encode(l), as: UTF8.self)
        XCTAssertFalse(json.contains("offline"))
    }
}
