import Foundation
import Network
import XCTest
@testable import WatchBridge
import WatchProtocol

final class RelayIdentityTests: XCTestCase {
    func testCreatesOnceAndKeepsPrivate() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("relay-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let a = try RelayIdentity.loadOrCreate(at: url)
        XCTAssertNotNil(a.macId.range(of: "^[a-z2-7]{26}$", options: .regularExpression))
        XCTAssertGreaterThanOrEqual(a.macSecret.count, 32)
        XCTAssertEqual(try RelayIdentity.loadOrCreate(at: url), a)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        XCTAssertNotNil(a.info(url: "wss://r")?.macKey)
    }

    func testBase32() {
        XCTAssertEqual(RelayIdentity.base32(Data("foobar".utf8)), "mzxw6ytboi")
    }
}

/// End to end against a running relay (`cd relay && npx wrangler dev`): `RELAY_URL=ws://127.0.0.1:8787 swift test --filter RelayLiveTests`.
final class RelayLiveTests: XCTestCase {
    private var relayURL: String!

    override func setUpWithError() throws {
        guard let u = ProcessInfo.processInfo.environment["RELAY_URL"] else { throw XCTSkip("RELAY_URL not set") }
        relayURL = u
    }

    /// A local "bridge" that answers every chunk with it uppercased.
    private func upperServer() throws -> (NWListener, UInt16) {
        let l = try NWListener(using: .tcp, on: .any)
        l.newConnectionHandler = { c in
            func loop() {
                c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { d, _, done, _ in
                    if let d { c.send(content: Data(String(decoding: d, as: UTF8.self).uppercased().utf8), completion: .idempotent) }
                    if !done { loop() }
                }
            }
            c.start(queue: .global()); loop()
        }
        let ready = expectation(description: "listening")
        l.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        l.start(queue: .global())
        wait(for: [ready], timeout: 5)
        return (l, l.port!.rawValue)
    }

    private func identity() throws -> RelayIdentity {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("relay-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        return try RelayIdentity.loadOrCreate(at: url)
    }

    private func waitConnected(_ c: RelayConnector) {
        let e = expectation(description: "connected")
        c.onStatus = { if $0 == .connected { e.fulfill() } }
        c.start()
        wait(for: [e], timeout: 10)
    }

    func testPhoneReachesMacThroughRelay() async throws {
        let (server, port) = try upperServer()
        defer { server.cancel() }
        let mac = try RelayConnector(url: relayURL, identity: identity(), localPort: port)
        waitConnected(mac)
        defer { mac.stop() }

        let session = URLSession(configuration: .ephemeral)
        for round in 0..<2 {   // two streams in a row on the same room
            let (ws, channel) = try await RelayStream.dial(mac.info!, session: session)
            try await ws.send(.data(channel.seal(Data("hello \(round)".utf8))))
            guard case .data(let frame) = try await ws.receive() else { return XCTFail("no frame") }
            XCTAssertEqual(String(decoding: try channel.open(frame), as: UTF8.self), "HELLO \(round)")
            ws.cancel(with: .normalClosure, reason: nil)
        }
    }

    func testMacOfflineIsReported() async throws {
        let info = try identity().info(url: relayURL)!
        do {
            _ = try await RelayStream.dial(info, session: URLSession(configuration: .ephemeral), timeout: 5)
            XCTFail("dialled an offline Mac")
        } catch {
            XCTAssertEqual((error as? RelayPipeError)?.errorDescription, "mac offline")
        }
    }

    func testOtherSecretCannotTakeTheRoom() throws {
        let real = try identity()
        let mac = try RelayConnector(url: relayURL, identity: real, localPort: 9)
        waitConnected(mac)
        mac.stop()
        var fake = real
        fake.macSecret = String(repeating: "x", count: 43)
        let thief = try RelayConnector(url: relayURL, identity: fake, localPort: 9)
        let e = expectation(description: "rejected")
        thief.onStatus = { if case .failed(let why) = $0 { XCTAssertEqual(why, "bad mac secret"); e.fulfill() } }
        thief.start()
        wait(for: [e], timeout: 10)
        thief.stop()
    }
}
