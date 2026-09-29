import Foundation
import WatchProtocol

enum RemoteError: LocalizedError, Equatable {
    /// 401: the Mac no longer knows this phone. Go back to pairing.
    case unauthorized
    /// No candidate host answered (Tailscale off, Mac asleep, wrong address).
    case unreachable(String)
    /// The bridge answered with an error body (`WireError`) or an unexpected status.
    case server(status: Int, message: String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: "This iPhone isn't paired with the Mac any more."
        case .unreachable(let why): "Couldn't reach your Mac. \(why)"
        case .server(_, let message): message
        case .badResponse(let why): "Unexpected answer from the Mac: \(why)"
        }
    }
}

/// REST + WebSocket access to the bridge. Tries the paired hosts in order and sticks to the first one
/// that answers until a request to it fails at the transport level.
actor RemoteClient {
    private(set) var credentials: Credentials
    private var base: URL?
    private let session: URLSession

    init(credentials: Credentials) {
        self.credentials = credentials
        self.session = Self.makeSession()
    }

    static func makeSession(timeout: TimeInterval = 12) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = 60
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }

    static func baseURL(host: String, port: Int) -> URL? {
        let h = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host   // bare IPv6
        return URL(string: "http://\(h):\(port)")
    }

    // MARK: Pairing

    /// Redeems a pairing code against the first host that answers. A wrong code stops at once (it counts
    /// against the Mac's attempt limit); only transport failures move on to the next host.
    static func pair(hosts: [String], port: Int, code: String, deviceName: String) async throws -> Credentials {
        let urls = hosts.compactMap { baseURL(host: $0.trimmingCharacters(in: .whitespaces), port: port) }
        guard !urls.isEmpty else { throw RemoteError.unreachable("No address to try.") }
        let session = makeSession(timeout: 6)
        let body = try WireCoder.encoder.encode(PairRequest(code: code, deviceName: deviceName))
        var lastError: Error = RemoteError.unreachable("")
        for (i, url) in urls.enumerated() {
            var req = URLRequest(url: url.appending(path: "pair"))
            req.httpMethod = "POST"
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                let (data, resp) = try await session.data(for: req)
                let r: PairResponse = try decode(data, resp)
                var ordered = urls
                ordered.insert(ordered.remove(at: i), at: 0)
                return Credentials(baseURLs: ordered, token: r.token, deviceId: r.deviceId, macName: r.macName)
            } catch let e as RemoteError {
                throw e
            } catch {
                lastError = RemoteError.unreachable(error.localizedDescription)
            }
        }
        throw lastError
    }

    // MARK: Reads

    func status() async throws -> BridgeStatus { try await get("v1/status") }
    func snapshot() async throws -> Snapshot { try await get("v1/snapshot") }

    func messages(chatId: String, before: Int?, limit: Int = 50) async throws -> MessagesPage {
        var q = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { q.append(URLQueryItem(name: "before", value: String(before))) }
        return try await get("v1/chats/\(chatId)/messages", query: q)
    }

    func folders(profileId: String) async throws -> [FolderSuggestion] {
        try await get("v1/folders", query: [URLQueryItem(name: "profile", value: profileId)])
    }

    func usage(profileId: String) async throws -> [UsageSample] {
        try await get("v1/accounts/\(profileId)/usage")
    }

    // MARK: Writes

    func register(_ r: DeviceRegistration) async throws -> BridgeStatus {
        try await send("POST", "v1/devices", body: try WireCoder.encoder.encode(r))
    }

    func unpair() async throws {
        let _: Empty = try await send("DELETE", "v1/devices/self", body: nil)
    }

    /// Posts a command; 202 → the job as the bridge knows it now (resending the same command re-reads it).
    func perform(_ c: RemoteCommand) async throws -> Job {
        let a: Accepted = try await send("POST", c.path, body: c.body)
        return a.job
    }

    // MARK: Stream

    func openStream() async throws -> StreamSocket {
        let base = try await resolveBase()
        var comps = URLComponents(url: base.appending(path: "v1/stream"), resolvingAgainstBaseURL: false)!
        comps.scheme = "ws"
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        return StreamSocket(task: session.webSocketTask(with: req))
    }

    /// Called when the stream failed at the transport level, so the next attempt re-probes the hosts.
    func forgetBase() { base = nil }

    // MARK: Plumbing

    private struct Empty: Decodable {}

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await send("GET", path, query: query, body: nil)
    }

    private func send<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [],
                                    body: Data?) async throws -> T {
        let base = try await resolveBase()
        // Command paths arrive already percent-encoded ("/v1/..."); read paths are plain segments.
        var url = path.hasPrefix("/") ? URL(string: base.absoluteString + path)! : base.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, resp) = try await session.data(for: req)
            return try Self.decode(data, resp)
        } catch let e as RemoteError {
            throw e
        } catch {
            self.base = nil
            throw RemoteError.unreachable(error.localizedDescription)
        }
    }

    /// The first candidate that answers `GET /v1/status` (any HTTP answer counts, even 401).
    private func resolveBase() async throws -> URL {
        if let base { return base }
        let probe = Self.makeSession(timeout: 4)
        var why = ""
        for url in credentials.baseURLs {
            var req = URLRequest(url: url.appending(path: "v1/status"))
            req.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
            do {
                let (_, resp) = try await probe.data(for: req)
                if (resp as? HTTPURLResponse)?.statusCode == 401 { throw RemoteError.unauthorized }
                base = url
                promote(url)
                return url
            } catch let e as RemoteError {
                throw e
            } catch {
                why = error.localizedDescription
            }
        }
        throw RemoteError.unreachable(why)
    }

    /// Remember the working host first so the next launch tries it before the others.
    private func promote(_ url: URL) {
        guard let i = credentials.baseURLs.firstIndex(of: url), i != 0 else { return }
        credentials.baseURLs.insert(credentials.baseURLs.remove(at: i), at: 0)
        Keychain.save(credentials)
    }

    private static func decode<T: Decodable>(_ data: Data, _ resp: URLResponse) throws -> T {
        guard let http = resp as? HTTPURLResponse else { throw RemoteError.badResponse("not HTTP") }
        switch http.statusCode {
        case 200..<300:
            if T.self == Empty.self || data.isEmpty, let e = Empty() as? T { return e }
            do { return try WireCoder.decoder.decode(T.self, from: data) } catch {
                throw RemoteError.badResponse(String(describing: error))
            }
        case 401:
            throw RemoteError.unauthorized
        default:
            let msg = (try? WireCoder.decoder.decode(WireError.self, from: data))?.error
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw RemoteError.server(status: http.statusCode, message: msg)
        }
    }
}

/// One `/v1/stream` connection.
final class StreamSocket: @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
        task.maximumMessageSize = 16 << 20
        task.resume()
    }

    func receive() async throws -> WSServerMessage {
        do {
            while true {
                let msg = try await task.receive()
                let data: Data
                switch msg {
                case .string(let s): data = Data(s.utf8)
                case .data(let d): data = d
                @unknown default: continue
                }
                // Unknown message types from a newer Mac are skipped rather than dropping the stream.
                if let m = try? WireCoder.decoder.decode(WSServerMessage.self, from: data) { return m }
            }
        } catch {
            if (task.response as? HTTPURLResponse)?.statusCode == 401 { throw RemoteError.unauthorized }
            throw RemoteError.unreachable(error.localizedDescription)
        }
    }

    func send(_ m: WSClientMessage) async throws {
        let data = try WireCoder.encoder.encode(m)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
    }
}
