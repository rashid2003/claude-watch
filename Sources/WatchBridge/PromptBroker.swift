import Darwin
import Foundation
import WatchProtocol

/// Receives approval requests from headless runs (the prompt tool) on a unix socket and holds each
/// one open until the phone answers, it times out (deny), or the run goes away.
public final class PromptBroker: @unchecked Sendable {
    public let path: String
    public static let timeout: TimeInterval = 600
    private let lock = NSLock()
    private var pending: [String: (prompt: PendingPrompt, fd: Int32)] = [:]
    private var listenFD: Int32 = -1
    /// Chat title and profile for a desktop session id.
    public var describe: ((String) -> (title: String, profileId: String)?)?
    public var onChange: (([PendingPrompt]) -> Void)?

    public init(path: String) { self.path = path }

    public var prompts: [PendingPrompt] { lock.withLock { pending.values.map(\.prompt).sorted { $0.at < $1.at } } }

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
        let all = lock.withLock { () -> [Int32] in let fds = pending.values.map(\.fd); pending = [:]; return fds }
        for fd in all { respond(fd, allow: false, message: "ClaudeWatch quit") }
        unlink(path)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 { if errno == EINTR { continue }; return }
            Thread.detachNewThread { [weak self] in self?.serve(c) }
        }
    }

    private func serve(_ fd: Int32) {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while data.firstIndex(of: 0x0A) == nil {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { close(fd); return }
            data.append(contentsOf: buf[0..<n])
            if data.count > 1 << 20 { close(fd); return }
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data[..<data.firstIndex(of: 0x0A)!])) as? [String: Any],
              let sessionId = obj["sessionId"] as? String else { close(fd); return }
        let d = describe?(sessionId)
        let detail = (obj["detail"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let prompt = PendingPrompt(id: "h-" + UUID().uuidString.prefix(8).lowercased(), chatId: sessionId,
                                   profileId: d?.profileId ?? "", chatTitle: d?.title ?? "Chat",
                                   toolName: obj["toolName"] as? String ?? "tool",
                                   summary: obj["summary"] as? String ?? "Run a tool", detail: detail,
                                   source: .headless, at: Date(), canAllowAlways: false)
        lock.withLock { pending[prompt.id] = (prompt, fd) }
        onChange?(prompts)
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
            _ = self?.answer(id: prompt.id, allow: false, message: "No answer from the phone within 10 minutes")
        }
    }

    /// Answers a pending headless prompt. False if it's gone.
    @discardableResult
    public func answer(id: String, allow: Bool, message: String? = nil) -> Bool {
        guard let entry = lock.withLock({ pending.removeValue(forKey: id) }) else { return false }
        respond(entry.fd, allow: allow, message: message)
        onChange?(prompts)
        return true
    }

    /// Drops the prompts of a chat whose run ended.
    public func clear(chatId: String) {
        let gone = lock.withLock { () -> [Int32] in
            let ids = pending.filter { $0.value.prompt.chatId == chatId }.map(\.key)
            return ids.compactMap { pending.removeValue(forKey: $0)?.fd }
        }
        for fd in gone { close(fd) }
        if !gone.isEmpty { onChange?(prompts) }
    }

    private func respond(_ fd: Int32, allow: Bool, message: String?) {
        var obj: [String: Any] = ["decision": allow ? "allow" : "deny"]
        if let message { obj["message"] = message }
        if var line = try? JSONSerialization.data(withJSONObject: obj) {
            line.append(0x0A)
            _ = line.withUnsafeBytes { write(fd, $0.baseAddress, line.count) }
        }
        close(fd)
    }
}
