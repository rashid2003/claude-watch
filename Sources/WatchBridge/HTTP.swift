import Foundation
import WatchProtocol

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]    // lowercased names
    public var body: Data

    public var bearer: String? {
        guard let a = headers["authorization"], a.lowercased().hasPrefix("bearer ") else { return nil }
        return String(a.dropFirst(7)).trimmingCharacters(in: .whitespaces)
    }
    /// Path split into components: "/v1/chats/x/reply" -> ["v1", "chats", "x", "reply"].
    public var parts: [String] { path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) } }

    public func decode<T: Decodable>(_ t: T.Type) -> T? { try? WireCoder.decoder.decode(t, from: body) }
}

public enum HTTPError: Error, Equatable { case malformed, tooLarge }

public enum HTTPParser {
    public static let maxSize = 1 << 20

    /// Parses one request from the start of `buf`. Nil = need more bytes.
    public static func parse(_ buf: Data) throws -> (HTTPRequest, consumed: Int)? {
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else {
            if buf.count > 64 * 1024 { throw HTTPError.tooLarge }
            return nil
        }
        let head = String(decoding: buf[buf.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count >= 2 else { throw HTTPError.malformed }
        var headers: [String: String] = [:]
        for l in lines {
            guard let c = l.firstIndex(of: ":") else { continue }
            headers[l[..<c].trimmingCharacters(in: .whitespaces).lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length >= 0, length <= maxSize else { throw HTTPError.tooLarge }
        let bodyStart = end.upperBound
        guard buf.distance(from: bodyStart, to: buf.endIndex) >= length else { return nil }
        let body = Data(buf[bodyStart..<buf.index(bodyStart, offsetBy: length)])
        let target = String(start[1])
        var path = target, query: [String: String] = [:]
        if let q = target.firstIndex(of: "?") {
            path = String(target[..<q])
            for item in URLComponents(string: "x:/?" + target[target.index(after: q)...])?.queryItems ?? [] {
                query[item.name] = item.value ?? ""
            }
        }
        let req = HTTPRequest(method: String(start[0]).uppercased(), path: path, query: query, headers: headers, body: body)
        return (req, buf.distance(from: buf.startIndex, to: bodyStart) + length)
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }

    public static func json<T: Encodable>(_ v: T, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "application/json"],
                     body: (try? WireCoder.encoder.encode(v)) ?? Data("{}".utf8))
    }

    public static func error(_ status: Int, _ message: String) -> HTTPResponse { json(WireError(message), status: status) }

    static let reasons = [200: "OK", 202: "Accepted", 204: "No Content", 400: "Bad Request", 401: "Unauthorized",
                          403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 409: "Conflict",
                          413: "Payload Too Large", 429: "Too Many Requests", 500: "Internal Server Error",
                          503: "Service Unavailable", 101: "Switching Protocols"]

    public func serialize() -> Data {
        var h = headers
        if status != 101 { h["Content-Length"] = String(body.count) }
        if h["Connection"] == nil && status != 101 { h["Connection"] = "keep-alive" }
        var s = "HTTP/1.1 \(status) \(Self.reasons[status] ?? "Status")\r\n"
        for (k, v) in h.sorted(by: { $0.key < $1.key }) { s += "\(k): \(v)\r\n" }
        s += "\r\n"
        return Data(s.utf8) + body
    }
}
