import XCTest
@testable import WatchBridge
import WatchProtocol

final class FakeSource: MessageSource {
    var queued: [ChatMessage] = []
    func poll() -> [ChatMessage] { defer { queued = [] }; return queued }
}

final class FakeHandler: BridgeHandler {
    var snap = Snapshot(at: Date(timeIntervalSince1970: 1_790_600_000), accounts: [], queue: [], engineOwner: true, scanning: false)
    var performed: [String] = []
    var busy = Set<String>()
    let source = FakeSource()
    var finish: ((JobStatus, String?) -> Void)?

    func snapshot() -> Snapshot? { snap }
    func status(for device: Device) -> BridgeStatus {
        BridgeStatus(macName: "Test Mac", version: "1", warnings: [], pushConfigured: false, deviceId: device.id, notify: device.notify)
    }
    func messages(chatId: String, before: Int?, limit: Int) -> MessagesPage? {
        chatId == "local_1" ? MessagesPage(messages: [ChatMessage(id: "m", kind: .user, at: Date(), text: "hi")], before: nil) : nil
    }
    func subscribe(chatId: String) -> (source: MessageSource, initial: [ChatMessage])? {
        guard chatId == "local_1" else { return nil }
        let initial = (0..<250).map { ChatMessage(id: "m\($0)", kind: .assistant, at: Date(), text: "\($0)") }
        return (source, initial)
    }
    func folders(profileId: String) -> [FolderSuggestion] { [FolderSuggestion(cwd: "/tmp", lastUsedAt: Date())] }
    func usage(profileId: String) -> [UsageSample] { [] }
    var health: SystemHealth?
    func systemHealth() -> SystemHealth? { health }
    func check(_ command: BridgeCommand) -> (Int, String)? {
        if case .reply(let c, _) = command, busy.contains(c) { return (409, "Claude is still working") }
        return nil
    }
    func perform(_ command: BridgeCommand, device: Device, done: @escaping (JobStatus, String?) -> Void) {
        performed.append(command.name)
        finish = done
    }
    var drafts: [String: String] = [:]
    func setDraft(chatId: String, text: String, device: Device) -> Bool {
        guard chatId == "local_1" else { return false }
        drafts[chatId] = text
        return true
    }
}

final class ServerTests: XCTestCase {
    var server: BridgeServer!
    var handler: FakeHandler!
    var port: UInt16 = 0
    var devicesURL: URL!

    override func setUp() {
        handler = FakeHandler()
        port = UInt16.random(in: 20000...40000)
        devicesURL = FileManager.default.temporaryDirectory.appendingPathComponent("devices-\(UUID().uuidString).json")
        let audit = AuditLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID().uuidString).jsonl"))
        server = BridgeServer(port: port, devices: DeviceStore(url: devicesURL), audit: audit, macName: "Test Mac",
                              handler: handler, hosts: { ["127.0.0.1"] })
        server.start()
        let ready = expectation(description: "listening")
        DispatchQueue.global().async { [self] in
            for _ in 0..<50 { if !server.boundHosts.isEmpty { break }; usleep(20_000) }
            usleep(100_000)
            ready.fulfill()
        }
        wait(for: [ready], timeout: 3)
    }

    override func tearDown() {
        server.stop()
        try? FileManager.default.removeItem(at: devicesURL)
    }

    func request(_ method: String, _ path: String, token: String? = nil, body: Encodable? = nil) async throws -> (Int, Data) {
        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        r.httpMethod = method
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { r.httpBody = try WireCoder.encoder.encode(body); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, resp) = try await URLSession.shared.data(for: r)
        return ((resp as! HTTPURLResponse).statusCode, data)
    }

    func pair() async throws -> String {
        let code = server.pairing.open()
        let (status, data) = try await request("POST", "/pair", body: PairRequest(code: code, deviceName: "Test iPhone"))
        XCTAssertEqual(status, 200)
        let r = try WireCoder.decoder.decode(PairResponse.self, from: data)
        XCTAssertEqual(r.macName, "Test Mac")
        return r.token
    }

    func testUnauthenticatedIsRejected() async throws {
        let (status, _) = try await request("GET", "/v1/snapshot")
        XCTAssertEqual(status, 401)
        let (s2, _) = try await request("GET", "/v1/snapshot", token: "nope")
        XCTAssertEqual(s2, 401)
    }

    func testPairingThenReads() async throws {
        let (bad, _) = try await request("POST", "/pair", body: PairRequest(code: "123", deviceName: "x"))
        XCTAssertEqual(bad, 403)
        let token = try await pair()
        let (s, data) = try await request("GET", "/v1/snapshot", token: token)
        XCTAssertEqual(s, 200)
        XCTAssertEqual(try WireCoder.decoder.decode(Snapshot.self, from: data).engineOwner, true)
        let (m, mdata) = try await request("GET", "/v1/chats/local_1/messages?limit=10", token: token)
        XCTAssertEqual(m, 200)
        XCTAssertEqual(try WireCoder.decoder.decode(MessagesPage.self, from: mdata).messages.first?.text, "hi")
        let (missing, _) = try await request("GET", "/v1/chats/nope/messages", token: token)
        XCTAssertEqual(missing, 404)
    }

    func testCommandsAreIdempotentAndCanBeRefused() async throws {
        let token = try await pair()
        let body = ReplyBody(requestId: "req-1", text: "continue")
        let (s1, d1) = try await request("POST", "/v1/chats/local_1/reply", token: token, body: body)
        let (s2, d2) = try await request("POST", "/v1/chats/local_1/reply", token: token, body: body)
        XCTAssertEqual(s1, 202); XCTAssertEqual(s2, 202)
        let j1 = try WireCoder.decoder.decode(Accepted.self, from: d1).job
        let j2 = try WireCoder.decoder.decode(Accepted.self, from: d2).job
        XCTAssertEqual(j1.id, j2.id)
        XCTAssertEqual(handler.performed, ["reply"], "ran once")

        handler.busy = ["local_2"]
        let (s3, d3) = try await request("POST", "/v1/chats/local_2/reply", token: token, body: ReplyBody(text: "hi"))
        XCTAssertEqual(s3, 409)
        XCTAssertEqual(try WireCoder.decoder.decode(WireError.self, from: d3).error, "Claude is still working")

        let (s4, _) = try await request("POST", "/v1/chats/local_1/reply", token: token, body: ReplyBody(text: "   "))
        XCTAssertEqual(s4, 400)
    }

    func testDraftsAreStoredWithoutAJob() async throws {
        let token = try await pair()
        let (s1, _) = try await request("POST", "/v1/chats/local_1/draft", token: token, body: DraftBody(text: "half"))
        XCTAssertEqual(s1, 204)
        XCTAssertEqual(handler.drafts["local_1"], "half")
        XCTAssertTrue(handler.performed.isEmpty)
        let (s2, _) = try await request("POST", "/v1/chats/nope/draft", token: token, body: DraftBody(text: "x"))
        XCTAssertEqual(s2, 404)
        let (s3, _) = try await request("POST", "/v1/chats/local_1/draft", token: token, body: ["nope": 1])
        XCTAssertEqual(s3, 400)
    }

    func testStreamSnapshotSubscriptionJobsAndRevoke() async throws {
        let token = try await pair()
        var r = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/v1/stream")!)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let ws = URLSession.shared.webSocketTask(with: r)
        ws.resume()
        func next() async throws -> WSServerMessage {
            let m = try await ws.receive()
            guard case .string(let s) = m else { throw URLError(.badServerResponse) }
            return try WireCoder.decoder.decode(WSServerMessage.self, from: Data(s.utf8))
        }
        guard case .snapshot = try await next() else { return XCTFail("snapshot first") }

        let sub = try WireCoder.encoder.encode(WSClientMessage(type: .subscribe, chatId: "local_1"))
        try await ws.send(.string(String(decoding: sub, as: UTF8.self)))
        guard case .messages(let id, let batch, let reset, let before) = try await next() else { return XCTFail("messages") }
        XCTAssertEqual(id, "local_1"); XCTAssertTrue(reset)
        XCTAssertEqual(batch.count, BridgeServer.initialBatch)
        XCTAssertEqual(before, 50)

        handler.source.queued = [ChatMessage(id: "new", kind: .assistant, at: Date(), text: "fresh")]
        guard case .messages(_, let more, false, _) = try await next() else { return XCTFail("update") }
        XCTAssertEqual(more.map(\.id), ["new"])

        let (_, d) = try await request("POST", "/v1/chats/local_1/stop", token: token, body: PlainCommand())
        let job = try WireCoder.decoder.decode(Accepted.self, from: d).job
        handler.finish?(.done, nil)
        guard case .job(let j) = try await next() else { return XCTFail("job event") }
        XCTAssertEqual(j.id, job.id); XCTAssertEqual(j.status, .done)

        var changed = handler.snap
        changed.engineOwner = false
        server.publish(snapshot: changed)
        guard case .snapshot(let s) = try await next() else { return XCTFail("republished snapshot") }
        XCTAssertFalse(s.engineOwner)

        let device = server.devices.all.first!
        server.revoke(deviceId: device.id)
        do { _ = try await next(); XCTFail("socket should close") } catch {}
        let (after, _) = try await request("GET", "/v1/snapshot", token: token)
        XCTAssertEqual(after, 401)
    }

    func testDeviceRegistration() async throws {
        let token = try await pair()
        let (s, data) = try await request("POST", "/v1/devices", token: token,
                                           body: DeviceRegistration(apnsToken: "abcd", environment: "sandbox", notify: ["finished": false]))
        XCTAssertEqual(s, 200)
        XCTAssertEqual(try WireCoder.decoder.decode(BridgeStatus.self, from: data).notify["finished"], false)
        let d = server.devices.all.first!
        XCTAssertEqual(d.apnsToken, "abcd")
        XCTAssertFalse(d.wants(.finished))
        XCTAssertTrue(d.wants(.prompt))
    }

    static func health(history: Int = 3) -> SystemHealth {
        SystemHealth(at: Date(timeIntervalSince1970: 1_790_600_000), level: .warn, reasons: ["swap 8.0/10 GB"],
                     pressure: .ok, memTotal: 32 << 30, memUsed: 20 << 30, memCompressed: 3 << 30,
                     swapUsed: 8 << 30, swapTotal: 10 << 30, diskFree: 80 << 30, diskTotal: 994 << 30,
                     load1: 6, load5: 5, cores: 10, thermal: "nominal",
                     apps: [AppUsage(id: "/Applications/Docker.app", name: "Docker", rss: 6 << 30, cpu: 40, processes: 7,
                                     pids: [501, 502], mainPid: 501, canQuit: true, canKill: true)],
                     cleanable: [], history: (0..<history).map {
                         HealthPoint(at: Date(timeIntervalSince1970: Double(1_790_600_000 + $0 * 5)), memUsed: 1, swapUsed: 2, diskFree: 3, load1: 4)
                     },
                     auto: AutoActSummary(enabled: false, afterSeconds: 120, quitApps: [], closeIdleClaude: false, cleanTargets: []))
    }

    func testSystemRoutesAndCommands() async throws {
        let token = try await pair()
        let (none, _) = try await request("GET", "/v1/system", token: token)
        XCTAssertEqual(none, 503)
        handler.health = Self.health()
        let (ok, data) = try await request("GET", "/v1/system", token: token)
        XCTAssertEqual(ok, 200)
        XCTAssertEqual(try WireCoder.decoder.decode(SystemHealth.self, from: data).history.count, 3)

        let cases: [(String, Encodable, String)] = [
            ("/v1/system/apps/quit", QuitAppBody(appId: "/Applications/Docker.app"), "quit-app"),
            ("/v1/system/processes/kill", KillBody(pid: 4411), "kill"),
            ("/v1/system/claude/close-idle", PlainCommand(), "close-idle-claude"),
            ("/v1/system/disk/clean", CleanBody(targets: ["npm"]), "clean-disk"),
            ("/v1/system/auto", AutoActBody(enabled: true), "auto-act"),
        ]
        for (path, body, name) in cases {
            let (s, _) = try await request("POST", path, token: token, body: body)
            XCTAssertEqual(s, 202, path)
            XCTAssertEqual(handler.performed.last, name)
        }
        let (empty, _) = try await request("POST", "/v1/system/disk/clean", token: token, body: CleanBody(targets: []))
        XCTAssertEqual(empty, 400)
    }

    func testWatchSystemStreamsReadings() async throws {
        let token = try await pair()
        handler.health = Self.health()
        var r = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/v1/stream")!)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let ws = URLSession.shared.webSocketTask(with: r)
        ws.resume()
        func next() async throws -> WSServerMessage {
            guard case .string(let s) = try await ws.receive() else { throw URLError(.badServerResponse) }
            return try WireCoder.decoder.decode(WSServerMessage.self, from: Data(s.utf8))
        }
        func send(_ k: WSClientMessage.Kind) async throws {
            try await ws.send(.string(String(decoding: try WireCoder.encoder.encode(WSClientMessage(type: k)), as: UTF8.self)))
        }
        guard case .snapshot = try await next() else { return XCTFail("snapshot first") }

        server.publish(system: Self.health())          // nobody watching yet: not sent
        try await send(.watchSystem)
        guard case .system(let full) = try await next() else { return XCTFail("full reading on watch") }
        XCTAssertEqual(full.history.count, 3)
        server.publish(system: Self.health(history: 5))
        guard case .system(let one) = try await next() else { return XCTFail("streamed reading") }
        XCTAssertEqual(one.history.count, 1)

        try await send(.unwatchSystem)
        try await send(.ping)   // the pong proves the server handled the unwatch before we publish
        guard case .pong = try await next() else { return XCTFail("pong") }
        server.publish(system: Self.health())
        try await send(.ping)
        guard case .pong = try await next() else { return XCTFail("no reading after unwatch, just the pong") }
        ws.cancel()
    }
}
