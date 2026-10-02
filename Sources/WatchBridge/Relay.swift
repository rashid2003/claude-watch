import CryptoKit
import Foundation
import Network
import WatchProtocol

/// This Mac's relay identity, created once and kept in `relay.json` (0600).
public struct RelayIdentity: Codable, Sendable, Equatable {
    public var macId: String       // 26 chars of lowercase base32: the relay room
    public var macSecret: String   // proves to the relay that this is that room's Mac
    public var staticKey: String   // X25519 private key, base64

    public static func loadOrCreate(at url: URL) throws -> RelayIdentity {
        if let data = try? Data(contentsOf: url), let id = try? JSONDecoder().decode(RelayIdentity.self, from: data),
           (try? id.privateKey) != nil {
            return id
        }
        let id = RelayIdentity(macId: base32(random(16)),
                               macSecret: random(32).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                                   .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: ""),
                               staticKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation.base64EncodedString())
        try JSONEncoder().encode(id).write(to: url, options: .atomic)
        chmod(url.path, 0o600)
        return id
    }

    public var privateKey: Curve25519.KeyAgreement.PrivateKey {
        get throws { try .init(rawRepresentation: Data(base64Encoded: staticKey) ?? Data()) }
    }

    /// What goes in the pairing QR.
    public func info(url: String) -> RelayInfo? {
        guard let key = try? privateKey else { return nil }
        return RelayInfo(url: url, macId: macId, macKey: key.publicKey.rawRepresentation.base64EncodedString())
    }

    private static func random(_ n: Int) -> Data {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return Data(b)
    }

    static func base32(_ data: Data) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var out = "", buffer = 0, bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte); bits += 8
            while bits >= 5 { out.append(alphabet[(buffer >> (bits - 5)) & 31]); bits -= 5 }
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return out
    }
}

/// Keeps this Mac reachable through the relay: holds the control socket open and, for every phone
/// stream the relay announces, dials a data socket and pipes it to the bridge on 127.0.0.1.
/// The bridge itself is unchanged; through here a phone looks like a loopback client.
public final class RelayConnector: @unchecked Sendable {
    public enum Status: Equatable, Sendable {
        case off, connecting, connected
        case failed(String)
    }

    public let identity: RelayIdentity
    public let url: String
    private let localPort: UInt16
    private let key: Curve25519.KeyAgreement.PrivateKey
    private let session: URLSession
    private let queue = DispatchQueue(label: "relay.connector")
    private var control: URLSessionWebSocketTask?
    private var pipes: [ObjectIdentifier: RelayPipe] = [:]
    private var running = false
    private var attempt = 0
    private var generation = 0
    public private(set) var status: Status = .off { didSet { if status != oldValue { onStatus?(status) } } }
    public var onStatus: ((Status) -> Void)?
    public var maxStreams = 32

    public init(url: String, identity: RelayIdentity, localPort: UInt16) throws {
        self.url = url; self.identity = identity; self.localPort = localPort
        key = try identity.privateKey
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.waitsForConnectivity = true
        session = URLSession(configuration: cfg)
    }

    public var info: RelayInfo? { identity.info(url: url) }
    public var streamCount: Int { queue.sync { pipes.count } }

    public func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            connect()
        }
    }

    public func stop() {
        queue.async { [self] in
            running = false
            generation += 1
            control?.cancel(with: .goingAway, reason: nil)
            control = nil
            pipes.values.forEach { $0.close() }
            pipes = [:]
            status = .off
        }
    }

    // MARK: Control socket

    private func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue("Bearer \(identity.macSecret)", forHTTPHeaderField: "Authorization")
        return r
    }

    private func connect() {
        guard running, let url = RelayInfo(url: url, macId: identity.macId, macKey: "").controlURL else {
            status = .failed("Bad relay address."); return
        }
        generation += 1
        let gen = generation
        status = .connecting
        let task = session.webSocketTask(with: request(url))
        control = task
        task.resume()
        Task { await listen(task, gen) }
        ping(task, gen)
    }

    private func listen(_ task: URLSessionWebSocketTask, _ gen: Int) async {
        do {
            while true {
                let msg = try await task.receive()
                guard case .string(let text) = msg,
                      let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String] else { continue }
                queue.async { [self] in
                    guard gen == generation else { return }
                    if status != .connected { status = .connected; attempt = 0 }
                    if obj["t"] == "open", let sid = obj["sid"] { openStream(sid) }
                }
            }
        } catch {
            queue.async { [self] in
                guard gen == generation, running else { return }
                let why = RelayStream.closeError(task)?.errorDescription ?? error.localizedDescription
                status = .failed(why)
                // Another copy of this Mac's identity took over the room: back off instead of fighting it.
                let replaced = why.contains("replaced")
                attempt += 1
                let delay = replaced ? 60 : min(60, 1 << min(attempt, 6))
                queue.asyncAfter(deadline: .now() + .seconds(delay)) { [self] in
                    if gen == generation, running { connect() }
                }
            }
        }
    }

    /// The relay answers `{"t":"ping"}` itself without waking up; the first pong also marks us connected.
    private func ping(_ task: URLSessionWebSocketTask, _ gen: Int) {
        guard gen == generation, running else { return }
        task.send(.string(#"{"t":"ping"}"#)) { _ in }
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in self?.ping(task, gen) }
    }

    // MARK: Streams

    private func openStream(_ sid: String) {
        guard pipes.count < maxStreams, let url = RelayInfo(url: url, macId: identity.macId, macKey: "").dataURL(sid: sid) else { return }
        let task = session.webSocketTask(with: request(url))
        task.maximumMessageSize = 2 << 20
        task.resume()
        Task { [self] in
            do {
                let channel = try await RelayStream.answer(task, staticKey: key)
                let local = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: localPort)!, using: .tcp)
                let pipe = RelayPipe(socket: task, local: local, channel: channel)
                let id = ObjectIdentifier(pipe)
                pipe.onClose = { [weak self] in self?.queue.async { self?.pipes[id] = nil } }
                local.stateUpdateHandler = { state in
                    switch state {
                    case .ready: pipe.run()
                    case .failed, .cancelled: pipe.close()
                    default: break
                    }
                }
                queue.async { [self] in
                    guard running else { return pipe.close() }
                    pipes[id] = pipe
                    local.start(queue: queue)
                }
            } catch {
                task.cancel(with: .normalClosure, reason: nil)
            }
        }
    }
}
