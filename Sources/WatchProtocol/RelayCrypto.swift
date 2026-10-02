import CryptoKit
import Foundation

/// How a phone reaches its Mac through the relay. Carried in the pairing QR and kept with the phone's credentials.
public struct RelayInfo: Codable, Sendable, Equatable {
    /// e.g. `wss://relay.sessionwatch.lajward.dev`
    public var url: String
    public var macId: String
    /// The Mac's static X25519 public key, base64. Pins the Mac: only it can answer a stream's hello.
    public var macKey: String
    public init(url: String, macId: String, macKey: String) {
        self.url = url; self.macId = macId; self.macKey = macKey
    }

    public var phoneURL: URL? { URL(string: url.trimmingSlash + "/v1/phone/" + macId) }
    public var controlURL: URL? { URL(string: url.trimmingSlash + "/v1/mac/" + macId) }
    public func dataURL(sid: String) -> URL? { URL(string: url.trimmingSlash + "/v1/mac/" + macId + "/" + sid) }
}

private extension String {
    var trimmingSlash: String { hasSuffix("/") ? String(dropLast()) : self }
}

public enum RelayCryptoError: Error, Equatable {
    case badFrame
    case badKey
    case decryptFailed
}

/// Per-stream key agreement (Noise-NK-like). The phone knows the Mac's static key from the QR:
///
///     phone → mac   0x01 ‖ ephP.pub
///     mac → phone   0x02 ‖ ephM.pub
///     ikm = DH(ephP, staticM) ‖ DH(ephP, ephM)
///     keys = HKDF-SHA256(ikm, salt, info: ephP.pub ‖ ephM.pub ‖ staticM.pub) → phone→mac ‖ mac→phone
///
/// The static DH authenticates the Mac; the Mac's fresh ephemeral key makes every stream's keys new,
/// so frames replayed by the relay into another stream don't open.
public enum RelayHandshake {
    public static let helloTag: UInt8 = 1
    public static let replyTag: UInt8 = 2
    static let salt = Data("session-watch relay v1".utf8)

    /// The phone's half: send `hello`, then `finish` with the Mac's reply.
    public struct Phone: Sendable {
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let macKey: Curve25519.KeyAgreement.PublicKey

        public init(macKey base64: String) throws {
            guard let raw = Data(base64Encoded: base64),
                  let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw) else { throw RelayCryptoError.badKey }
            macKey = key
        }

        public var hello: Data { Data([helloTag]) + eph.publicKey.rawRepresentation }

        public func finish(reply: Data) throws -> RelayChannel {
            guard reply.count == 33, reply.first == replyTag,
                  let ephM = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: reply.dropFirst()) else {
                throw RelayCryptoError.badFrame
            }
            let keys = try derive(dhStatic: eph.sharedSecretFromKeyAgreement(with: macKey),
                                  dhEph: eph.sharedSecretFromKeyAgreement(with: ephM),
                                  ephP: eph.publicKey, ephM: ephM, staticM: macKey)
            return RelayChannel(send: keys.toMac, receive: keys.toPhone)
        }
    }

    /// The Mac's half: answers a phone's hello.
    public static func accept(hello: Data, staticKey: Curve25519.KeyAgreement.PrivateKey) throws -> (reply: Data, channel: RelayChannel) {
        guard hello.count == 33, hello.first == helloTag,
              let ephP = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: hello.dropFirst()) else {
            throw RelayCryptoError.badFrame
        }
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let keys = try derive(dhStatic: staticKey.sharedSecretFromKeyAgreement(with: ephP),
                              dhEph: eph.sharedSecretFromKeyAgreement(with: ephP),
                              ephP: ephP, ephM: eph.publicKey, staticM: staticKey.publicKey)
        return (Data([replyTag]) + eph.publicKey.rawRepresentation, RelayChannel(send: keys.toPhone, receive: keys.toMac))
    }

    private static func derive(dhStatic: SharedSecret, dhEph: SharedSecret,
                               ephP: Curve25519.KeyAgreement.PublicKey, ephM: Curve25519.KeyAgreement.PublicKey,
                               staticM: Curve25519.KeyAgreement.PublicKey) throws -> (toMac: SymmetricKey, toPhone: SymmetricKey) {
        let ikm = dhStatic.withUnsafeBytes { Data($0) } + dhEph.withUnsafeBytes { Data($0) }
        let info = ephP.rawRepresentation + ephM.rawRepresentation + staticM.rawRepresentation
        let okm = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt, info: info, outputByteCount: 64)
        let bytes = okm.withUnsafeBytes { Data($0) }
        return (SymmetricKey(data: bytes.prefix(32)), SymmetricKey(data: bytes.suffix(32)))
    }
}

/// An established stream: ChaCha20-Poly1305 with a per-direction counter nonce. Frames must arrive in
/// order and exactly once; anything else fails to open and the stream should be closed.
public final class RelayChannel: @unchecked Sendable {
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sent: UInt64 = 0
    private var received: UInt64 = 0
    private let lock = NSLock()

    init(send: SymmetricKey, receive: SymmetricKey) {
        sendKey = send; receiveKey = receive
    }

    public func seal(_ plaintext: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let box = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: Self.nonce(sent))
        sent += 1
        return Data(box.ciphertext) + box.tag   // ciphertext is a slice of the combined box; rebase it at 0
    }

    public func open(_ frame: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard frame.count >= 16 else { throw RelayCryptoError.badFrame }
        do {
            let box = try ChaChaPoly.SealedBox(nonce: Self.nonce(received), ciphertext: frame.dropLast(16), tag: frame.suffix(16))
            let plain = try ChaChaPoly.open(box, using: receiveKey)
            received += 1
            return plain
        } catch {
            throw RelayCryptoError.decryptFailed
        }
    }

    private static func nonce(_ n: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(count: 12)
        withUnsafeBytes(of: n.littleEndian) { bytes.replaceSubrange(0..<8, with: $0) }
        return try! ChaChaPoly.Nonce(data: bytes)
    }
}
