import Darwin
import Foundation

/// A tiny stdio MCP server that Claude Code calls as its `--permission-prompt-tool` during headless
/// runs. Each call is forwarded to ClaudeWatch over a unix socket and waits for the phone's answer.
/// Protocol on the socket: one JSON line each way.
///   → {"sessionId","toolName","toolUseId","summary","detail"}
///   ← {"decision":"allow"|"deny","message"?}
public enum PromptTool {
    public struct Answer: Equatable {
        public var allow: Bool
        public var message: String?
        public init(allow: Bool, message: String?) { self.allow = allow; self.message = message }
    }
    public typealias Ask = (_ toolName: String, _ input: [String: Any], _ toolUseId: String?) -> Answer

    /// Handles one JSON-RPC message; nil for notifications (no reply).
    public static func handle(_ req: [String: Any], ask: Ask) -> [String: Any]? {
        guard let method = req["method"] as? String else { return nil }
        let id = req["id"]
        func reply(_ result: Any) -> [String: Any] { ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result] }
        switch method {
        case "initialize":
            let version = (req["params"] as? [String: Any])?["protocolVersion"] as? String ?? "2025-06-18"
            return reply(["protocolVersion": version, "capabilities": ["tools": [:]],
                          "serverInfo": ["name": "claudewatch", "version": "1"]])
        case "tools/list":
            return reply(["tools": [[
                "name": "approve",
                "description": "Asks the user on their phone whether a tool may run.",
                "inputSchema": ["type": "object",
                                "properties": ["tool_name": ["type": "string"], "input": ["type": "object"],
                                               "tool_use_id": ["type": "string"]],
                                "required": ["tool_name", "input"]],
            ]]])
        case "tools/call":
            let args = ((req["params"] as? [String: Any])?["arguments"] as? [String: Any]) ?? [:]
            let input = args["input"] as? [String: Any] ?? [:]
            let a = ask(args["tool_name"] as? String ?? "tool", input, args["tool_use_id"] as? String)
            let decision: [String: Any] = a.allow ? ["behavior": "allow", "updatedInput": input]
                                                  : ["behavior": "deny", "message": a.message ?? "Denied from the phone"]
            let text = (try? JSONSerialization.data(withJSONObject: decision)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            return reply(["content": [["type": "text", "text": text]]])
        case "ping":
            return reply([String: Any]())
        default:
            if id == nil { return nil }
            return ["jsonrpc": "2.0", "id": id!, "error": ["code": -32601, "message": "Method not found"]]
        }
    }

    /// Runs the stdio loop until stdin closes (`claude-watch prompt-tool --socket <path> --session <id>`).
    public static func serve(socketPath: String, sessionId: String) {
        while let line = readLine(strippingNewline: true) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            let out = handle(obj) { tool, input, useId in
                ask(socketPath: socketPath, sessionId: sessionId, tool: tool, input: input, toolUseId: useId)
            }
            if let out, let data = try? JSONSerialization.data(withJSONObject: out) {
                FileHandle.standardOutput.write(data + Data([0x0A]))
            }
        }
    }

    public static func ask(socketPath: String, sessionId: String, tool: String, input: [String: Any], toolUseId: String?) -> Answer {
        let fields = input.compactMapValues { $0 as? String }
        let info = SessionInfo(id: sessionId, cliSessionId: nil, priorCliSessionIds: [], profileId: "", accountUuid: "",
                               title: "", cwd: "", model: nil, permissionMode: nil, lastActivityAt: Date(),
                               isArchived: false, desktopError: nil, desktopErrorAt: nil, hasPendingPermission: true)
        let p = PromptDetector.prompt(for: info, tool: OpenToolUse(id: toolUseId ?? UUID().uuidString, name: tool,
                                                                    fields: fields, at: Date()), source: .headless)
        let req: [String: Any] = ["sessionId": sessionId, "toolName": tool, "toolUseId": toolUseId ?? "",
                                  "summary": p.summary, "detail": p.detail ?? ""]
        guard let body = try? JSONSerialization.data(withJSONObject: req) else { return Answer(allow: false, message: "bad request") }
        guard let line = UnixSocket.request(path: socketPath, line: body, timeout: 600) else {
            return Answer(allow: false, message: "Couldn't reach ClaudeWatch to ask for approval")
        }
        let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        return Answer(allow: obj?["decision"] as? String == "allow", message: obj?["message"] as? String)
    }
}

/// Blocking unix-domain socket client: send one line, read one line.
public enum UnixSocket {
    public static func request(path: String, line: Data, timeout: TimeInterval) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
            buf[bytes.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { return nil }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let out = line + Data([0x0A])
        let sent = out.withUnsafeBytes { write(fd, $0.baseAddress, out.count) }
        guard sent == out.count else { return nil }
        var result = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            result.append(contentsOf: buf[0..<n])
            if let nl = result.firstIndex(of: 0x0A) { return result[..<nl] }
        }
        return result.isEmpty ? nil : result
    }
}
