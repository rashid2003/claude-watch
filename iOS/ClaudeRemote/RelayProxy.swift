import Foundation
import Network
import WatchProtocol

/// Lets URLSession reach the Mac through the relay as if it were a plain HTTP server: an in-app
/// listener on 127.0.0.1, where every accepted connection becomes one end-to-end encrypted relay
/// stream to the Mac's bridge. RemoteClient then needs nothing relay-specific beyond the base URL.
final class RelayProxy: @unchecked Sendable {
    static let shared = RelayProxy()

    private let queue = DispatchQueue(label: "relay.proxy")
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()
    private var listener: NWListener?
    private var port: UInt16?
    private var info: RelayInfo?
    private var pipes: [ObjectIdentifier: RelayPipe] = [:]
    private var _lastError: String?

    /// Why the last stream couldn't reach the Mac ("mac offline", …), for error messages.
    var lastError: String? { queue.sync { _lastError } }

    /// `http://127.0.0.1:<port>` for `info`, starting (or restarting, after iOS suspended it) the listener.
    func baseURL(for info: RelayInfo) async throws -> URL {
        let bound: UInt16 = try await withCheckedThrowingContinuation { c in
            queue.async { [self] in
                if self.info != info { stopLocked() }
                self.info = info
                if let port, listener != nil { return c.resume(returning: port) }
                startLocked(c)
            }
        }
        return URL(string: "http://127.0.0.1:\(bound)")!
    }

    func stop() { queue.async { [self] in stopLocked(); info = nil } }

    private func stopLocked() {
        listener?.cancel()
        listener = nil
        port = nil
        pipes.values.forEach { $0.close() }
        pipes = [:]
    }

    private func startLocked(_ c: CheckedContinuation<UInt16, Error>) {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        params.acceptLocalOnly = true
        let l: NWListener
        do { l = try NWListener(using: params) } catch { return c.resume(throwing: error) }
        var resumed = false
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, let l else { return }
            switch state {
            case .ready:
                port = l.port?.rawValue
                if !resumed, let port { resumed = true; c.resume(returning: port) }
            case .failed(let e):
                if listener === l { listener = nil; port = nil }
                if !resumed { resumed = true; c.resume(throwing: e) }
            case .cancelled:
                if listener === l { listener = nil; port = nil }
                if !resumed { resumed = true; c.resume(throwing: CancellationError()) }
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener = l
        l.start(queue: queue)
    }

    private func accept(_ local: NWConnection) {
        guard let info else { return local.cancel() }
        Task { [self] in
            do {
                let (ws, channel) = try await RelayStream.dial(info, session: session)
                let pipe = RelayPipe(socket: ws, local: local, channel: channel)
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
                    _lastError = nil
                    pipes[id] = pipe
                    local.start(queue: queue)
                }
            } catch {
                queue.async { [self] in _lastError = Self.describe(error) }
                local.cancel()
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        switch (error as? RelayPipeError)?.errorDescription {
        case "mac offline": "Your Mac isn't connected to the relay. Is Session Watch running with the relay on?"
        case let why?: why
        case nil: error.localizedDescription
        }
    }
}
