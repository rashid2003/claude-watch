import CryptoKit
import Foundation

/// Just enough RFC 6455 for one server: handshake key, unmasked server frames, masked client frames.
public enum WebSocket {
    public enum Opcode: UInt8, Sendable { case cont = 0, text = 1, binary = 2, close = 8, ping = 9, pong = 10 }
    public enum FrameError: Error, Equatable { case unmasked, tooLarge, badOpcode }
    public static let maxPayload = 1 << 20

    public static func acceptKey(for key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        return Data(digest).base64EncodedString()
    }

    public static func encode(_ op: Opcode, _ payload: Data) -> Data {
        var out = Data([0x80 | op.rawValue])
        switch payload.count {
        case ..<126: out.append(UInt8(payload.count))
        case ..<65536:
            out.append(126)
            out.append(UInt8(payload.count >> 8)); out.append(UInt8(payload.count & 0xFF))
        default:
            out.append(127)
            for i in (0..<8).reversed() { out.append(UInt8((UInt64(payload.count) >> (8 * UInt64(i))) & 0xFF)) }
        }
        return out + payload
    }

    /// One frame from the start of `buf`; nil = need more bytes. Client frames must be masked.
    /// Fragmented messages are not supported (URLSession never sends them for small messages).
    public static func decode(_ buf: Data) throws -> (op: Opcode, payload: Data, consumed: Int)? {
        let b = [UInt8](buf.prefix(14))
        guard b.count >= 2 else { return nil }
        guard let op = Opcode(rawValue: b[0] & 0x0F) else { throw FrameError.badOpcode }
        guard b[1] & 0x80 != 0 else { throw FrameError.unmasked }
        var len = Int(b[1] & 0x7F)
        var at = 2
        if len == 126 {
            guard b.count >= 4 else { return nil }
            len = Int(b[2]) << 8 | Int(b[3]); at = 4
        } else if len == 127 {
            guard b.count >= 10 else { return nil }
            var v: UInt64 = 0
            for i in 2..<10 { v = v << 8 | UInt64(b[i]) }
            guard v <= UInt64(maxPayload) else { throw FrameError.tooLarge }
            len = Int(v); at = 10
        }
        guard len <= maxPayload else { throw FrameError.tooLarge }
        guard buf.count >= at + 4 + len else { return nil }
        let mask = [UInt8](buf[buf.index(buf.startIndex, offsetBy: at)..<buf.index(buf.startIndex, offsetBy: at + 4)])
        let start = buf.index(buf.startIndex, offsetBy: at + 4)
        var payload = [UInt8](buf[start..<buf.index(start, offsetBy: len)])
        for i in payload.indices { payload[i] ^= mask[i & 3] }
        return (op, Data(payload), at + 4 + len)
    }

    /// Client-side framing (masked); used by tests.
    public static func encodeMasked(_ op: Opcode, _ payload: Data, mask: [UInt8] = [1, 2, 3, 4]) -> Data {
        var out = Data([0x80 | op.rawValue])
        switch payload.count {
        case ..<126: out.append(0x80 | UInt8(payload.count))
        case ..<65536: out.append(0x80 | 126); out.append(UInt8(payload.count >> 8)); out.append(UInt8(payload.count & 0xFF))
        default:
            out.append(0x80 | 127)
            for i in (0..<8).reversed() { out.append(UInt8((UInt64(payload.count) >> (8 * UInt64(i))) & 0xFF)) }
        }
        out.append(contentsOf: mask)
        out.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset & 3] })
        return out
    }
}
