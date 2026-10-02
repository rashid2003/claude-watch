import XCTest
@testable import WatchBridge
import WatchProtocol

final class HTTPTests: XCTestCase {
    func testGetWithQuery() throws {
        let raw = Data("GET /v1/chats/local_1/messages?before=10&limit=50 HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer abc\r\n\r\n".utf8)
        let (r, n) = try XCTUnwrap(try HTTPParser.parse(raw))
        XCTAssertEqual(n, raw.count)
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.parts, ["v1", "chats", "local_1", "messages"])
        XCTAssertEqual(r.query["before"], "10")
        XCTAssertEqual(r.bearer, "abc")
    }

    func testBodySplitAcrossReads() throws {
        let body = #"{"requestId":"r","text":"hi"}"#
        let raw = Data("POST /v1/chats/c/reply HTTP/1.1\r\ncontent-LENGTH: \(body.utf8.count)\r\n\r\n\(body)".utf8)
        XCTAssertNil(try HTTPParser.parse(raw.prefix(raw.count - 5)))
        let (r, _) = try XCTUnwrap(try HTTPParser.parse(raw))
        XCTAssertEqual(r.decode(ReplyBody.self)?.text, "hi")
    }

    func testPipelinedRequestsConsumeOnlyTheFirst() throws {
        let one = "GET /a HTTP/1.1\r\n\r\n"
        let (r, n) = try XCTUnwrap(try HTTPParser.parse(Data((one + "GET /b HTTP/1.1\r\n\r\n").utf8)))
        XCTAssertEqual(r.path, "/a")
        XCTAssertEqual(n, one.utf8.count)
    }

    func testOversizeBodyRejected() {
        let raw = Data("POST / HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n".utf8)
        XCTAssertThrowsError(try HTTPParser.parse(raw)) { XCTAssertEqual($0 as? HTTPError, .tooLarge) }
    }

    func testResponseSerialisation() {
        let s = String(decoding: HTTPResponse.error(401, "nope").serialize(), as: UTF8.self)
        XCTAssertTrue(s.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
        XCTAssertTrue(s.contains("Content-Length: 16\r\n"))
        XCTAssertTrue(s.hasSuffix("\r\n\r\n{\"error\":\"nope\"}"))
    }
}

final class WebSocketTests: XCTestCase {
    func testAcceptKeyFromRFC() {
        XCTAssertEqual(WebSocket.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    func testMaskedHelloFromRFC() throws {
        let frame = Data([0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58])
        let (op, payload, n) = try XCTUnwrap(try WebSocket.decode(frame))
        XCTAssertEqual(op, .text)
        XCTAssertEqual(String(decoding: payload, as: UTF8.self), "Hello")
        XCTAssertEqual(n, frame.count)
    }

    func testLengthForms() throws {
        for size in [5, 300, 70_000] {
            let p = Data(repeating: 0x41, count: size)
            let (_, out, n) = try XCTUnwrap(try WebSocket.decode(WebSocket.encodeMasked(.binary, p)))
            XCTAssertEqual(out, p); XCTAssertEqual(n, WebSocket.encodeMasked(.binary, p).count)
            let server = WebSocket.encode(.text, p)
            XCTAssertEqual(server.count, p.count + (size < 126 ? 2 : size < 65536 ? 4 : 10))
        }
    }

    func testUnmaskedClientFrameRejectedAndPartialWaits() {
        XCTAssertThrowsError(try WebSocket.decode(WebSocket.encode(.text, Data("x".utf8))))
        XCTAssertNil(try WebSocket.decode(WebSocket.encodeMasked(.text, Data("hello".utf8)).prefix(4)))
    }
}

final class AuthTests: XCTestCase {
    func tempURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("dev-\(UUID().uuidString).json") }

    func testTokensAreHashedAndAuthenticate() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DeviceStore(url: url)
        let (d, token) = store.add(name: "iPhone")
        XCTAssertEqual(store.authenticate(token)?.id, d.id)
        XCTAssertNil(store.authenticate(token + "x"))
        XCTAssertNil(store.authenticate(nil))
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(onDisk.contains(token))
        XCTAssertEqual(DeviceStore(url: url).authenticate(token)?.name, "iPhone", "survives reload")
        store.remove(id: d.id)
        XCTAssertNil(store.authenticate(token))
    }

    func testPairingCodeExpiresAndIsSingleUse() {
        let g = PairingGate()
        let t = Date()
        let code = g.open(now: t)
        XCTAssertFalse(g.redeem(code, now: t.addingTimeInterval(121)))
        let c2 = g.open(now: t)
        XCTAssertTrue(g.redeem(c2, now: t.addingTimeInterval(5)))
        XCTAssertFalse(g.redeem(c2, now: t.addingTimeInterval(6)))
    }

    func testPairingLocksAfterFiveFailures() {
        let g = PairingGate()
        let code = g.open()
        let wrong = code == "000000" ? "000001" : "000000"
        for _ in 0..<5 { XCTAssertFalse(g.redeem(wrong)) }
        XCTAssertFalse(g.redeem(code))
        XCTAssertFalse(g.isOpen)
    }

    func testPeerFilter() {
        XCTAssertTrue(PeerFilter.allowed("127.0.0.1"))
        XCTAssertTrue(PeerFilter.allowed("::1"))
        XCTAssertTrue(PeerFilter.allowed("100.64.0.1"))
        XCTAssertTrue(PeerFilter.allowed("100.127.255.254"))
        XCTAssertFalse(PeerFilter.allowed("100.128.0.1"))
        XCTAssertFalse(PeerFilter.allowed("192.168.1.2"))
        XCTAssertTrue(PeerFilter.allowed("fd7a:115c:a1e0::1"))
        XCTAssertTrue(PeerFilter.allowed("fd7a:115c:a1e0:ab12::1%utun4"))
        XCTAssertFalse(PeerFilter.allowed("fe80::1"))
        XCTAssertTrue(PeerFilter.allowed("::ffff:100.100.1.1"))
    }
}

final class JobsTests: XCTestCase {
    func testIdempotentStartAndFinish() {
        let book = JobBook()
        var changes: [JobStatus] = []
        book.onChange = { j, dev in XCTAssertEqual(dev, "d1"); changes.append(j.status) }
        let (a, new1) = book.start(requestId: "r1", command: "reply", target: "c", deviceId: "d1")
        let (b, new2) = book.start(requestId: "r1", command: "reply", target: "c", deviceId: "d1")
        XCTAssertTrue(new1); XCTAssertFalse(new2); XCTAssertEqual(a.id, b.id)
        let (c, new3) = book.start(requestId: "r1", command: "reply", target: "c", deviceId: "d2")
        XCTAssertTrue(new3); XCTAssertNotEqual(c.id, a.id)
        book.finish(a.id, .done)
        XCTAssertEqual(changes, [.done])
        XCTAssertEqual(book.job(a.id)?.status, .done)
    }

    func testCapacity() {
        let book = JobBook()
        let (first, _) = book.start(requestId: "r0", command: "x", target: nil, deviceId: "d")
        for i in 1...JobBook.capacity { _ = book.start(requestId: "r\(i)", command: "x", target: nil, deviceId: "d") }
        XCTAssertNil(book.job(first.id))
        XCTAssertTrue(book.start(requestId: "r0", command: "x", target: nil, deviceId: "d").isNew)
    }

    func testAuditAppends() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = AuditLog(url: url)
        log.append(device: "iPhone", command: "reply", target: "c", result: "done")
        log.append(device: "iPhone", command: "stop", target: "c", result: "failed", reason: "not running")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count, 2)
        XCTAssertEqual(log.last?.text, "stop failed · iPhone")
    }
}

final class TailnetOwnerTests: XCTestCase {
    let status = Data(#"{"Self":{"UserID":42,"DNSName":"mac.tail1.ts.net."},"User":{"42":{"LoginName":"rashid@lajward.dev"}}}"#.utf8)

    func whois(_ login: String) -> Data { Data(#"{"UserProfile":{"LoginName":"\#(login)"}}"#.utf8) }

    func testAllowsOnlyTheMacsOwner() {
        var calls: [[String]] = []
        let owner = TailnetOwner { args in
            calls.append(args)
            if args.first == "status" { return self.status }
            return args.last == "100.64.0.2" ? self.whois("Rashid@lajward.dev") : self.whois("someone@else.com")
        }
        XCTAssertTrue(owner.allows("100.64.0.2"))
        XCTAssertFalse(owner.allows("100.64.0.3"))
        XCTAssertNotNil(owner.lastRefused)
        XCTAssertTrue(owner.allows("100.64.0.2"), "cached")
        XCTAssertEqual(calls.filter { $0.first == "whois" }.count, 2)
        XCTAssertEqual(calls.filter { $0.first == "status" }.count, 1)
    }

    func testTaggedAndUnknownDevicesAreRefused() {
        let owner = TailnetOwner { $0.first == "status" ? self.status : ($0.last == "100.64.0.9" ? nil : self.whois("tagged-devices")) }
        XCTAssertFalse(owner.allows("100.64.0.8"))
        XCTAssertFalse(owner.allows("100.64.0.9"))
    }

    func testWithoutTheCLIFallsBackToAddressAndToken() {
        let owner = TailnetOwner { _ in nil }
        XCTAssertTrue(owner.allows("fd7a:115c:a1e0::5%utun4"))
        XCTAssertTrue(owner.unavailable)
    }

    func testRetriesARefusedPeerAfterThirtySeconds() {
        var login = "someone@else.com"
        let owner = TailnetOwner { $0.first == "status" ? self.status : self.whois(login) }
        let t = Date()
        XCTAssertFalse(owner.allows("100.64.0.2", now: t))
        login = "rashid@lajward.dev"
        XCTAssertFalse(owner.allows("100.64.0.2", now: t.addingTimeInterval(10)))
        XCTAssertTrue(owner.allows("100.64.0.2", now: t.addingTimeInterval(31)))
    }
}
