import Darwin
import Foundation
import WatchProtocol

/// Receives approval requests on a unix socket and holds each one open until the phone answers,
/// it times out, or the asker goes away. Two kinds of askers:
/// - the prompt tool of a headless run (`claude-watch prompt-tool`): a timeout denies;
/// - the terminal prompt hook (`claude-watch prompt-hook`, request has `"hook": true`): a timeout,
///   or no phone to ask, answers `"defer"` so the terminal's own prompt decides.
public final class PromptBroker: @unchecked Sendable {
    public let path: String
    public static let timeout: TimeInterval = 600
    /// Longest a terminal hook request is held, whatever it asks for.
    public static let hookMaxWait: TimeInterval = 600
    private let lock = NSLock()
    private var pending: [String: (prompt: PendingPrompt, fd: Int32)] = [:]
    private var listenFD: Int32 = -1
    /// Chat title and profile for a desktop session id.
    public var describe: ((String) -> (title: String, profileId: String)?)?
    /// Whether to put a terminal hook request in front of the phone (a phone can be reached and the
    /// chat is a terminal chat). False or unset: the hook is told to defer at once.
    public var holdHook: ((_ sessionId: String) -> Bool)?
    public var onChange: (([PendingPrompt]) -> Void)?

    public init(path: String) { self.path = path }

    public var prompts: [PendingPrompt] { lock.withLock { pending.values.map(\.prompt).sorted { $0.at < $1.at } } }

    /// Hook prompts have ids starting with this (headless ones with "h-").
    public static let hookPrefix = "k-"
    public static func isHook(_ promptId: String) -> Bool { promptId.hasPrefix(hookPrefix) }

    public func start() throws {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
            buf[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        chmod(path, 0o600)
        listenFD = fd
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
    }

    public func stop() {
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        for id in lock.withLock({ Array(pending.keys) }) {
            finish(id: id, reply: Self.isHook(id) ? ["decision": "defer"] : ["decision": "deny", "message": "ClaudeWatch quit"])
        }
        unlink(path)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 { if errno == EINTR { continue }; return }
            Thread.detachNewThread { [weak self] in self?.serve(c) }
        }
    }

    /// One asker's connection. This thread owns the descriptor: it closes it once the request is
    /// answered (by `finish`), timed out, or the asker hangs up.
    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while data.firstIndex(of: 0x0A) == nil {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { return }
            data.append(contentsOf: buf[0..<n])
            if data.count > 1 << 20 { return }
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data[..<data.firstIndex(of: 0x0A)!])) as? [String: Any],
              let sessionId = obj["sessionId"] as? String else { return }
        let hook = obj["hook"] as? Bool == true
        if hook, holdHook?(sessionId) != true {
            Self.write(fd, ["decision": "defer"])
            return
        }
        let d = describe?(sessionId)
        let detail = (obj["detail"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let prompt = PendingPrompt(id: (hook ? Self.hookPrefix : "h-") + UUID().uuidString.prefix(8).lowercased(), chatId: sessionId,
                                   profileId: d?.profileId ?? "", chatTitle: d?.title ?? "Chat",
                                   toolName: obj["toolName"] as? String ?? "tool",
                                   summary: obj["summary"] as? String ?? "Run a tool", detail: detail,
                                   source: .headless, at: Date(), canAllowAlways: false)
        lock.withLock { pending[prompt.id] = (prompt, fd) }
        onChange?(prompts)

        let wait = hook ? min(Self.hookMaxWait, max(1, (obj["wait"] as? NSNumber)?.doubleValue ?? Self.hookMaxWait)) : Self.timeout
        let deadline = Date().addingTimeInterval(wait)
        while lock.withLock({ pending[prompt.id] != nil }) {
            if Date() >= deadline {
                finish(id: prompt.id, reply: hook ? ["decision": "defer"]
                                                  : ["decision": "deny", "message": "No answer from the phone within 10 minutes"])
                break
            }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 500) > 0 else { continue }
            // The asker never sends more than its one line: readable now means it hung up.
            var b: UInt8 = 0
            if read(fd, &b, 1) <= 0, lock.withLock({ pending.removeValue(forKey: prompt.id) }) != nil {
                onChange?(prompts)
            }
        }
    }

    /// Answers a pending prompt. False if it's gone.
    @discardableResult
    public func answer(id: String, allow: Bool, message: String? = nil) -> Bool {
        var reply: [String: Any] = ["decision": allow ? "allow" : "deny"]
        if let message { reply["message"] = message }
        return finish(id: id, reply: reply)
    }

    /// Hands a terminal hook prompt back to the terminal (its own prompt decides). False if it's gone.
    @discardableResult
    public func release(id: String) -> Bool { finish(id: id, reply: ["decision": "defer"]) }

    /// Drops the prompts of a chat whose run ended.
    public func clear(chatId: String) {
        let ids = lock.withLock { pending.filter { $0.value.prompt.chatId == chatId }.map(\.key) }
        for id in ids { finish(id: id, reply: Self.isHook(id) ? ["decision": "defer"] : nil) }
    }

    /// Removes a prompt and writes its reply (nil: none), under the lock so the serving thread
    /// can't close the descriptor mid-write. The serving thread closes it.
    @discardableResult
    private func finish(id: String, reply: [String: Any]?) -> Bool {
        let done = lock.withLock { () -> Bool in
            guard let entry = pending.removeValue(forKey: id) else { return false }
            if let reply { Self.write(entry.fd, reply) }
            shutdown(entry.fd, SHUT_RDWR)
            return true
        }
        if done { onChange?(prompts) }
        return done
    }

    private static func write(_ fd: Int32, _ obj: [String: Any]) {
        guard var line = try? JSONSerialization.data(withJSONObject: obj) else { return }
        line.append(0x0A)
        _ = line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, line.count) }
    }
}
