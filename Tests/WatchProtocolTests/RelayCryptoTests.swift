import CryptoKit
import XCTest
@testable import WatchProtocol

final class RelayCryptoTests: XCTestCase {
    private let mac = Curve25519.KeyAgreement.PrivateKey()
    private var macKey: String { mac.publicKey.rawRepresentation.base64EncodedString() }

    private func handshake() throws -> (phone: RelayChannel, mac: RelayChannel) {
        let phone = try RelayHandshake.Phone(macKey: macKey)
        let (reply, macSide) = try RelayHandshake.accept(hello: phone.hello, staticKey: mac)
        return (try phone.finish(reply: reply), macSide)
    }

    func testBothSidesTalk() throws {
        let (phone, macSide) = try handshake()
        for i in 0..<3 {
            let up = Data("GET /v1/status \(i)".utf8)
            XCTAssertEqual(try macSide.open(phone.seal(up)), up)
            let down = Data("HTTP/1.1 200 OK \(i)".utf8)
            XCTAssertEqual(try phone.open(macSide.seal(down)), down)
        }
        XCTAssertEqual(try macSide.open(phone.seal(Data())), Data())
    }

    func testTamperedFrameFails() throws {
        let (phone, macSide) = try handshake()
        var frame = try phone.seal(Data("hello".utf8))
        frame[0] ^= 1
        XCTAssertThrowsError(try macSide.open(frame))
    }

    func testReplayedAndReorderedFramesFail() throws {
        let (phone, macSide) = try handshake()
        let a = try phone.seal(Data("a".utf8)), b = try phone.seal(Data("b".utf8))
        XCTAssertThrowsError(try macSide.open(b))   // out of order
        _ = try macSide.open(a)
        XCTAssertThrowsError(try macSide.open(a))   // replay
        XCTAssertEqual(try macSide.open(b), Data("b".utf8))
    }

    func testFramesDontCrossStreams() throws {
        let one = try handshake(), two = try handshake()
        XCTAssertThrowsError(try two.mac.open(one.phone.seal(Data("x".utf8))))
    }

    func testImpostorMacCannotAnswer() throws {
        let phone = try RelayHandshake.Phone(macKey: macKey)
        let (reply, impostor) = try RelayHandshake.accept(hello: phone.hello, staticKey: .init())
        let channel = try phone.finish(reply: reply)
        XCTAssertThrowsError(try channel.open(impostor.seal(Data("hi".utf8))))
        XCTAssertThrowsError(try impostor.open(channel.seal(Data("hi".utf8))))
    }

    func testBadHandshakeFrames() {
        XCTAssertThrowsError(try RelayHandshake.Phone(macKey: "not base64"))
        XCTAssertThrowsError(try RelayHandshake.accept(hello: Data([2]) + Data(count: 32), staticKey: mac))
        XCTAssertThrowsError(try RelayHandshake.accept(hello: Data([1, 2, 3]), staticKey: mac))
    }

    func testPairingPayloadVersions() throws {
        let v1 = PairingPayload(macName: "Mac", hosts: ["h"], port: 7433, code: "123456")
        XCTAssertEqual(v1.v, 1)
        let info = RelayInfo(url: "wss://relay.example/", macId: String(repeating: "a", count: 26), macKey: macKey)
        let v2 = PairingPayload(macName: "Mac", hosts: [], port: 7433, code: "123456", relay: info)
        XCTAssertEqual(v2.v, 2)
        let back = try WireCoder.decoder.decode(PairingPayload.self, from: WireCoder.encoder.encode(v2))
        XCTAssertEqual(back, v2)
        XCTAssertEqual(info.phoneURL?.absoluteString, "wss://relay.example/v1/phone/" + info.macId)
        // A v1 QR from an older Mac still decodes.
        let old = #"{"v":1,"macName":"Mac","hosts":["h"],"port":7433,"code":"1"}"#
        XCTAssertNil(try WireCoder.decoder.decode(PairingPayload.self, from: Data(old.utf8)).relay)
    }
}
