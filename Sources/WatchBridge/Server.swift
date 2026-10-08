import Foundation
import Network
import WatchProtocol

/// Something the phone asked the Mac to do.
public enum BridgeCommand: Sendable {
    case reply(chatId: String, text: String)
    case answer(chatId: String, promptId: String, decision: PromptDecision)
    case stop(chatId: String)
    case newChat(profileId: String, cwd: String, prompt: String)
    case retry(itemId: String)
    case cancelRetry(itemId: String)
    case setMode(profileId: String, mode: RetryMode)
    case move(sessionId: String, toLocationId: String)
    case undoMove(id: String)
    case cancelMove(id: String)
    case restartMoves

    public var name: String {
        switch self {
        case .reply: "reply"
        case .answer: "prompt"
        case .stop: "stop"
        case .newChat: "new-chat"
        case .retry: "retry"
        case .cancelRetry: "cancel-retry"
        case .setMode: "mode"
        case .move: "move"
        case .undoMove: "undo-move"
        case .cancelMove: "cancel-move"
        case .restartMoves: "restart-windows"
        }
    }

    public var target: String? {
        switch self {
        case .reply(let c, _), .answer(let c, _, _), .stop(let c): c
        case .newChat(let p, _, _), .setMode(let p, _): p
        case .retry(let i), .cancelRetry(let i): i
        case .move(let s, _): s
        case .undoMove(let i), .cancelMove(let i): i
        case .restartMoves: nil
        }
    }
}

/// A live feed of one chat's messages (ChatFeed on the Mac).
public protocol MessageSource: AnyObject {
    func poll() -> [ChatMessage]
}

/// What the bridge needs from the app. Called on the bridge's queue; implementations must be thread-safe
/// and must not block for long except in `perform`, which should hand work off and call `done` later.
public protocol BridgeHandler: AnyObject {
    func snapshot() -> Snapshot?
    func status(for device: Device) -> BridgeStatus
    func messages(chatId: String, before: Int?, limit: Int) -> MessagesPage?
    /// A feed for a chat plus the messages it has so far.
    func subscribe(chatId: String) -> (source: MessageSource, initial: [ChatMessage])?
    func folders(profileId: String) -> [FolderSuggestion]
    func usage(profileId: String) -> [UsageSample]
    /// Refuse a command up front: (HTTP status, message), or nil to accept it.
    func check(_ command: BridgeCommand) -> (Int, String)?
    func perform(_ command: BridgeCommand, device: Device, done: @escaping (JobStatus, String?) -> Void)
}

public final class BridgeServer: @unchecked Sendable {
    public let port: UInt16
    public let devices: DeviceStore
    public let pairing = PairingGate()
    public let jobs = JobBook()
    public let audit: AuditLog
    public let macName: String
    public weak var handler: BridgeHandler?
    /// Called when a phone pairs or a device record changes (push token, preferences, removal).
    public var onDevicesChanged: (() -> Void)?
    /// Addresses currently listened on.
    public private(set) var boundHosts: [String] = []
    public private(set) var lastError: String?
    /// Extra check for non-loopback peers (the Tailscale owner check); nil admits every tailnet address.
    public var peerCheck: ((String) -> Bool)?

    private let hosts: () -> [String]
    private let queue = DispatchQueue(label: "claude-watch.bridge")
    private var listeners: [String: NWListener] = [:]
    private var conns: [ObjectIdentifier: Conn] = [:]
    private var timers: [DispatchSourceTimer] = []
    private var lastSnapshotKey: Data?
    private var lastSnapshotData: Data?
    static let initialBatch = 200

    public init(port: UInt16, devices: DeviceStore, audit: AuditLog, macName: String,
                handler: BridgeHandler?, hosts: @escaping () -> [String]) {
        self.port = port; self.devices = devices; self.audit = audit; self.macName = macName
        self.handler = handler; self.hosts = hosts
        jobs.onChange = { [weak self] job, deviceId in self?.queue.async { self?.send(.job(job), toDevice: deviceId) } }
    }

    // MARK: Lifecycle

    public func start() {
        queue.async { [self] in
            rebind()
            let rebindTimer = DispatchSource.makeTimerSource(queue: queue)
            rebindTimer.schedule(deadline: .now() + 60, repeating: 60)
            rebindTimer.setEventHandler { [weak self] in self?.rebind() }
            let feedTimer = DispatchSource.makeTimerSource(queue: queue)
            feedTimer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
            feedTimer.setEventHandler { [weak self] in self?.pollFeeds() }
            let pingTimer = DispatchSource.makeTimerSource(queue: queue)
            pingTimer.schedule(deadline: .now() + 20, repeating: 20)
            pingTimer.setEventHandler { [weak self] in self?.pingAll() }
            timers = [rebindTimer, feedTimer, pingTimer]
            timers.forEach { $0.resume() }
        }
    }

    public func stop() {
        queue.sync {
            timers.forEach { $0.cancel() }
            timers = []
            listeners.values.forEach { $0.cancel() }
            listeners = [:]
            conns.values.forEach { $0.c.cancel() }
            conns = [:]
            boundHosts = []
        }
    }

    /// Listens on exactly the wanted addresses; called at start and every minute (Tailscale can come and go).
    private func rebind() {
        let want = Set(hosts())
        for (h, l) in listeners where !want.contains(h) { l.cancel(); listeners[h] = nil }
        for h in want where listeners[h] == nil {
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(h), port: NWEndpoint.Port(rawValue: port)!)
                let l = try NWListener(using: params)
                l.newConnectionHandler = { [weak self] c in self?.accept(c) }
                l.stateUpdateHandler = { [weak self] st in
                    if case .failed(let e) = st {
                        self?.queue.async { [weak self] in
                            self?.lastError = "Can't listen on \(h):\(self?.port ?? 0): \(e)"
                            guard let self else { return }
                            self.listeners[h]?.cancel(); self.listeners[h] = nil
                            self.boundHosts = self.listeners.keys.sorted()
                        }
                    }
                }
                l.start(queue: queue)
                listeners[h] = l
            } catch {
                lastError = "Can't listen on \(h):\(port): \(error)"
            }
        }
        boundHosts = listeners.keys.sorted()
    }

    // MARK: Publishing

    /// Sends the snapshot to every connected phone when it changed.
    public func publish(snapshot: Snapshot) {
        queue.async { [self] in
            var keyed = snapshot
            keyed.at = .distantPast
            let key = try? WireCoder.encoder.encode(keyed)
            guard key != lastSnapshotKey, let data = try? WireCoder.encoder.encode(WSServerMessage.snapshot(snapshot)) else { return }
            lastSnapshotKey = key
            lastSnapshotData = data
            for c in conns.values where c.isSocket { c.sendText(data) }
        }
    }

    /// Forgets a device and drops its connections.
    public func revoke(deviceId: String) {
        devices.remove(id: deviceId)
        queue.async { [self] in
            for c in conns.values where c.device?.id == deviceId { c.close() }
        }
        onDevicesChanged?()
    }

    private func send(_ m: WSServerMessage, toDevice id: String) {
        guard let data = try? WireCoder.encoder.encode(m) else { return }
        for c in conns.values where c.isSocket && c.device?.id == id { c.sendText(data) }
    }

    private func pollFeeds() {
        for c in conns.values where c.isSocket {
            guard let (chatId, feed) = c.feed else { continue }
            let new = feed.poll()
            if !new.isEmpty, let data = try? WireCoder.encoder.encode(
                WSServerMessage.messages(chatId: chatId, messages: new, reset: false, before: nil)) {
                c.sendText(data)
            }
        }
    }

    private func pingAll() {
        for c in conns.values where c.isSocket { c.send(WebSocket.encode(.ping, Data())) }
    }

    // MARK: Connections

    final class Conn {
        let c: NWConnection
        var buf = Data()
        var isSocket = false
        var device: Device?
        var feed: (String, MessageSource)?
        weak var server: BridgeServer?

        init(_ c: NWConnection) { self.c = c }

        func send(_ d: Data) { c.send(content: d, completion: .contentProcessed { _ in }) }
        func sendText(_ d: Data) { send(WebSocket.encode(.text, d)) }
        func respond(_ r: HTTPResponse) { send(r.serialize()) }
        func close() {
            if isSocket { send(WebSocket.encode(.close, Data([0x03, 0xE8]))) }
            c.send(content: nil, isComplete: true, completion: .contentProcessed { [c] _ in c.cancel() })
        }
    }

    private func accept(_ c: NWConnection) {
        guard case .hostPort(let host, _) = c.endpoint, PeerFilter.allowed("\(host)") else {
            c.cancel()
            return
        }
        let h = "\(host)"
        guard let check = peerCheck, !PeerFilter.isLoopback(h) else { return admit(c) }
        // `tailscale whois` takes a moment; don't hold up the server queue for it.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = check(h)
            self?.queue.async { if ok { self?.admit(c) } else { c.cancel() } }
        }
    }

    private func admit(_ c: NWConnection) {
        let conn = Conn(c)
        conn.server = self
        conns[ObjectIdentifier(conn)] = conn
        c.stateUpdateHandler = { [weak self, weak conn] st in
            switch st {
            case .failed, .cancelled: if let conn { self?.conns[ObjectIdentifier(conn)] = nil }
            default: break
            }
        }
        c.start(queue: queue)
        receive(conn)
    }

    private func receive(_ conn: Conn) {
        conn.c.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self, weak conn] data, _, done, err in
            guard let self, let conn else { return }
            if let data { conn.buf.append(data) }
            self.drain(conn)
            if done || err != nil { conn.c.cancel(); self.conns[ObjectIdentifier(conn)] = nil; return }
            self.receive(conn)
        }
    }

    private func drain(_ conn: Conn) {
        while !conn.buf.isEmpty {
            if conn.isSocket {
                let frame: (op: WebSocket.Opcode, payload: Data, consumed: Int)?
                do { frame = try WebSocket.decode(conn.buf) } catch { conn.close(); return }
                guard let f = frame else { return }
                conn.buf.removeFirst(f.consumed)
                onFrame(conn, f.op, f.payload)
            } else {
                let parsed: (HTTPRequest, consumed: Int)?
                do { parsed = try HTTPParser.parse(conn.buf) } catch {
                    conn.respond(.error(413, "Request too large")); conn.close(); return
                }
                guard let (req, n) = parsed else { return }
                conn.buf.removeFirst(n)
                handle(req, on: conn)
            }
        }
    }

    private func onFrame(_ conn: Conn, _ op: WebSocket.Opcode, _ payload: Data) {
        switch op {
        case .ping: conn.send(WebSocket.encode(.pong, payload))
        case .close: conn.close()
        case .text:
            guard let m = try? WireCoder.decoder.decode(WSClientMessage.self, from: payload) else { return }
            switch m.type {
            case .ping:
                if let id = conn.device?.id { devices.touch(id) }   // tells the Live Activity driver the app is open
                if let d = try? WireCoder.encoder.encode(WSServerMessage.pong) { conn.sendText(d) }
            case .unsubscribe: conn.feed = nil
            case .watchSystem, .unwatchSystem: break
            case .subscribe:
                guard let id = m.chatId, let sub = handler?.subscribe(chatId: id) else { conn.feed = nil; return }
                conn.feed = (id, sub.source)
                let start = max(0, sub.initial.count - Self.initialBatch)
                let msg = WSServerMessage.messages(chatId: id, messages: Array(sub.initial[start...]), reset: true,
                                                   before: start > 0 ? start : nil)
                if let d = try? WireCoder.encoder.encode(msg) { conn.sendText(d) }
            }
        default: break
        }
    }

    // MARK: HTTP

    private func handle(_ req: HTTPRequest, on conn: Conn) {
        let p = req.parts
        if req.method == "POST", p == ["pair"] { return conn.respond(pair(req)) }
        guard let device = devices.authenticate(req.bearer) else { return conn.respond(.error(401, "Not paired")) }
        devices.touch(device.id)
        conn.device = device

        if req.method == "GET", p == ["v1", "stream"] { return upgrade(req, conn) }
        guard p.first == "v1" else { return conn.respond(.error(404, "Not found")) }
        conn.respond(route(req, Array(p.dropFirst()), device))
    }

    private func upgrade(_ req: HTTPRequest, _ conn: Conn) {
        guard req.headers["upgrade"]?.lowercased() == "websocket", let key = req.headers["sec-websocket-key"] else {
            return conn.respond(.error(400, "Expected a WebSocket upgrade"))
        }
        conn.respond(HTTPResponse(status: 101, headers: ["Upgrade": "websocket", "Connection": "Upgrade",
                                                         "Sec-WebSocket-Accept": WebSocket.acceptKey(for: key)]))
        conn.isSocket = true
        if let data = lastSnapshotData {
            conn.sendText(data)
        } else if let s = handler?.snapshot(), let data = try? WireCoder.encoder.encode(WSServerMessage.snapshot(s)) {
            conn.sendText(data)
        }
    }

    private func pair(_ req: HTTPRequest) -> HTTPResponse {
        guard let body = req.decode(PairRequest.self) else { return .error(400, "Bad pairing request") }
        guard pairing.redeem(body.code) else { return .error(403, "That code is wrong or expired. Open Pair iPhone… on the Mac again.") }
        let (d, token) = devices.add(name: body.deviceName)
        audit.append(device: d.name, command: "pair", target: d.id, result: "done")
        onDevicesChanged?()
        return .json(PairResponse(token: token, deviceId: d.id, macName: macName))
    }

    private func route(_ req: HTTPRequest, _ p: [String], _ device: Device) -> HTTPResponse {
        guard let handler else { return .error(503, "The Mac app is starting") }
        switch (req.method, p.count, p.first) {
        case ("GET", 1, "status"):
            return .json(handler.status(for: device))
        case ("GET", 1, "snapshot"):
            return handler.snapshot().map { .json($0) } ?? .error(503, "No data yet")
        case ("GET", 3, "chats") where p[2] == "messages":
            let page = handler.messages(chatId: p[1], before: req.query["before"].flatMap(Int.init),
                                        limit: min(500, req.query["limit"].flatMap(Int.init) ?? 50))
            return page.map { .json($0) } ?? .error(404, "No such chat")
        case ("GET", 1, "folders"):
            return .json(handler.folders(profileId: req.query["profile"] ?? ""))
        case ("GET", 3, "accounts") where p[2] == "usage":
            return .json(handler.usage(profileId: p[1]))
        case ("POST", 1, "devices"):
            guard let r = req.decode(DeviceRegistration.self) else { return .error(400, "Bad body") }
            devices.update(device.id) { d in
                if let t = r.apnsToken { d.apnsToken = t; d.apnsEnvironment = r.environment ?? "production" }
                if let n = r.notify { d.notify.merge(n) { $1 } }
                if let on = r.liveActivity { d.liveActivity = on }
                if let t = r.activityToken {
                    if t != d.activityToken { d.activityStartedAt = t.isEmpty ? nil : Date() }
                    d.activityToken = t.isEmpty ? nil : t
                }
                if let t = r.activityStartToken { d.activityStartToken = t.isEmpty ? nil : t }
                if r.environment != nil, r.apnsToken == nil { d.apnsEnvironment = r.environment }
            }
            onDevicesChanged?()
            return .json(handler.status(for: devices.all.first { $0.id == device.id } ?? device))
        case ("DELETE", 2, "devices") where p[1] == "self":
            revoke(deviceId: device.id)
            return HTTPResponse(status: 204)
        case ("POST", _, _):
            return command(req, p, device, handler)
        default:
            return .error(404, "Not found")
        }
    }

    private func command(_ req: HTTPRequest, _ p: [String], _ device: Device, _ handler: BridgeHandler) -> HTTPResponse {
        var requestId = req.decode(PlainCommand.self)?.requestId ?? UUID().uuidString
        let cmd: BridgeCommand?
        switch (p.first, p.count, p.last) {
        case ("chats", 2, "new"):
            let b = req.decode(NewChatBody.self)
            cmd = b.map { .newChat(profileId: $0.profileId, cwd: $0.cwd, prompt: $0.prompt) }
        case ("chats", 3, "reply"):
            let b = req.decode(ReplyBody.self)
            cmd = b.flatMap { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .reply(chatId: p[1], text: $0.text) }
        case ("chats", 3, "prompt"):
            cmd = req.decode(PromptAnswerBody.self).map { .answer(chatId: p[1], promptId: $0.promptId, decision: $0.decision) }
        case ("chats", 3, "stop"): cmd = .stop(chatId: p[1])
        case ("queue", 3, "retry"): cmd = .retry(itemId: p[1])
        case ("queue", 3, "cancel"): cmd = .cancelRetry(itemId: p[1])
        case ("accounts", 3, "mode"): cmd = req.decode(ModeBody.self).map { .setMode(profileId: p[1], mode: $0.mode) }
        case ("moves", 1, _): cmd = req.decode(MoveBody.self).map { .move(sessionId: $0.sessionId, toLocationId: $0.toLocationId) }
        case ("moves", 2, "restart"): cmd = .restartMoves
        case ("moves", 3, "undo"): cmd = .undoMove(id: p[1])
        case ("moves", 3, "cancel"): cmd = .cancelMove(id: p[1])
        default: return .error(404, "Not found")
        }
        guard let cmd else { return .error(400, "Bad body") }
        if requestId.isEmpty { requestId = UUID().uuidString }
        let (job, isNew) = jobs.start(requestId: requestId, command: cmd.name, target: cmd.target, deviceId: device.id)
        guard isNew else { return .json(Accepted(job: job), status: 202) }
        if let (status, message) = handler.check(cmd) {
            jobs.finish(job.id, .failed, reason: message)
            audit.append(device: device.name, command: cmd.name, target: cmd.target, result: "refused", reason: message)
            return .error(status, message)
        }
        audit.append(device: device.name, command: cmd.name, target: cmd.target, result: "accepted")
        handler.perform(cmd, device: device) { [weak self] status, reason in
            self?.jobs.finish(job.id, status, reason: reason)
            self?.audit.append(device: device.name, command: cmd.name, target: cmd.target, result: status.rawValue, reason: reason)
        }
        return .json(Accepted(job: job), status: 202)
    }
}
