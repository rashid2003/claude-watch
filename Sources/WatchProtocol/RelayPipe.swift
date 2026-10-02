import CryptoKit
import Foundation
import Network

public enum RelayPipeError: LocalizedError {
    case closed(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .closed(let why): why.isEmpty ? "The relay closed the connection." : why
        case .timeout: "The relay didn't answer in time."
        }
    }
}

/// One relay stream once keys are agreed: plaintext bytes on a local TCP connection ↔ sealed frames on a
/// relay WebSocket. Used by the Mac (local side = its bridge on 127.0.0.1) and the iPhone (local side =
/// URLSession talking to the in-app proxy). Either side ending closes both.
public final class RelayPipe: @unchecked Sendable {
    private let socket: URLSessionWebSocketTask
    private let local: NWConnection
    private let channel: RelayChannel
    private let lock = NSLock()
    private var closed = false
    public var onClose: (@Sendable () -> Void)?

    public init(socket: URLSessionWebSocketTask, local: NWConnection, channel: RelayChannel) {
        self.socket = socket; self.local = local; self.channel = channel
    }

    /// `local` must already be started.
    public func run() {
        pumpLocal()
        Task { await pumpSocket() }
    }

    public func close() {
        lock.lock()
        let first = !closed
        closed = true
        lock.unlock()
        guard first else { return }
        socket.cancel(with: .normalClosure, reason: nil)
        local.cancel()
        onClose?()
    }

    private func pumpLocal() {
        local.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    let frame = try channel.seal(data)
                    socket.send(.data(frame)) { [weak self] err in
                        if err != nil { self?.close() } else if !done { self?.pumpLocal() } else { self?.close() }
                    }
                } catch { close() }
                return
            }
            if done || error != nil { close() } else { pumpLocal() }
        }
    }

    private func pumpSocket() async {
        do {
            while true {
                let frame: Data
                switch try await socket.receive() {
                case .data(let d): frame = d
                case .string(let s): frame = Data(s.utf8)
                @unknown default: continue
                }
                let plain = try channel.open(frame)
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    local.send(content: plain, completion: .contentProcessed { err in
                        if let err { c.resume(throwing: err) } else { c.resume() }
                    })
                }
            }
        } catch {
            close()
        }
    }
}

/// The two ends of a stream's handshake over its relay WebSocket.
public enum RelayStream {
    /// Phone: dial the Mac through the relay and agree keys. Throws `RelayPipeError.closed("mac offline")`
    /// and similar when the relay turns the stream away.
    public static func dial(_ info: RelayInfo, session: URLSession, timeout: TimeInterval = 10) async throws -> (URLSessionWebSocketTask, RelayChannel) {
        guard let url = info.phoneURL else { throw RelayPipeError.closed("Bad relay address.") }
        let hs = try RelayHandshake.Phone(macKey: info.macKey)
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 2 << 20
        task.resume()
        do {
            try await task.send(.data(hs.hello))
            let reply = try await receiveData(task, timeout: timeout)
            return (task, try hs.finish(reply: reply))
        } catch {
            task.cancel(with: .normalClosure, reason: nil)
            throw closeError(task) ?? error
        }
    }

    /// Mac: wait for the phone's hello on a fresh data socket and answer it.
    public static func answer(_ task: URLSessionWebSocketTask, staticKey: RelayHandshakeKey, timeout: TimeInterval = 10) async throws -> RelayChannel {
        let hello = try await receiveData(task, timeout: timeout)
        let (reply, channel) = try RelayHandshake.accept(hello: hello, staticKey: staticKey)
        try await task.send(.data(reply))
        return channel
    }

    /// The relay's reason for closing, once a task has been closed by it.
    public static func closeError(_ task: URLSessionWebSocketTask) -> RelayPipeError? {
        guard let r = task.closeReason, let why = String(data: r, encoding: .utf8), !why.isEmpty else { return nil }
        return .closed(why)
    }

    static func receiveData(_ task: URLSessionWebSocketTask, timeout: TimeInterval) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                switch try await task.receive() {
                case .data(let d): return d
                case .string(let s): return Data(s.utf8)
                @unknown default: throw RelayCryptoError.badFrame
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                task.cancel(with: .normalClosure, reason: nil)   // unblocks the receive above
                throw RelayPipeError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw RelayPipeError.timeout }
            return first
        }
    }
}

public typealias RelayHandshakeKey = Curve25519.KeyAgreement.PrivateKey
