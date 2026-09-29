import CryptoKit
import Darwin
import Foundation
import WatchProtocol

/// A paired phone. Only a SHA-256 of its token is stored.
public struct Device: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var tokenHash: String
    public var createdAt: Date
    public var lastSeenAt: Date?
    public var apnsToken: String?
    public var apnsEnvironment: String?
    public var notify: [String: Bool] = [:]

    public func wants(_ e: NotifyEvent) -> Bool { notify[e.rawValue] ?? true }
}

public final class DeviceStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var devices: [Device] = []

    public init(url: URL) {
        self.url = url
        if let d = try? Data(contentsOf: url), let list = try? WireCoder.decoder.decode([Device].self, from: d) { devices = list }
    }

    public var all: [Device] { lock.withLock { devices } }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// Creates a device and returns its one-time-visible token.
    public func add(name: String, now: Date = Date()) -> (Device, token: String) {
        let token = Self.randomToken()
        let d = Device(id: "dev-" + UUID().uuidString.prefix(8).lowercased(), name: String(name.prefix(80)),
                       tokenHash: Self.hash(token), createdAt: now)
        lock.withLock { devices.append(d) }
        save()
        return (d, token)
    }

    public func authenticate(_ bearer: String?) -> Device? {
        guard let bearer, !bearer.isEmpty else { return nil }
        let h = Data(Self.hash(bearer).utf8)
        return lock.withLock {
            devices.first { Self.constantTimeEqual(Data($0.tokenHash.utf8), h) }
        }
    }

    public func update(_ id: String, _ change: (inout Device) -> Void) {
        lock.withLock { if let i = devices.firstIndex(where: { $0.id == id }) { change(&devices[i]) } }
        save()
    }

    /// Marks a device as seen; saved at most once a minute.
    public func touch(_ id: String, now: Date = Date()) {
        var needSave = false
        lock.withLock {
            if let i = devices.firstIndex(where: { $0.id == id }) {
                if (devices[i].lastSeenAt.map { now.timeIntervalSince($0) > 60 } ?? true) { needSave = true }
                devices[i].lastSeenAt = now
            }
        }
        if needSave { save() }
    }

    public func remove(id: String) {
        lock.withLock { devices.removeAll { $0.id == id } }
        save()
    }

    private func save() {
        let list = all
        guard let data = try? WireCoder.encoder.encode(list) else { return }
        try? data.write(to: url, options: .atomic)
        chmod(url.path, 0o600)
    }

    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }
}

/// The 6-digit code shown with the QR code. Valid for 2 minutes, once; five wrong tries close it.
public final class PairingGate: @unchecked Sendable {
    public static let lifetime: TimeInterval = 120
    public static let maxFailures = 5
    private let lock = NSLock()
    private var code: String?
    private var expires: Date = .distantPast
    private var failures = 0
    public var onClose: (() -> Void)?

    public init() {}

    public var isOpen: Bool { lock.withLock { code != nil && Date() < expires } }

    @discardableResult
    public func open(now: Date = Date(), code fixed: String? = nil, lifetime: TimeInterval = PairingGate.lifetime) -> String {
        let c = fixed ?? String(format: "%06d", Int.random(in: 0..<1_000_000))
        lock.withLock { code = c; expires = now.addingTimeInterval(lifetime); failures = 0 }
        return c
    }

    public func close() {
        lock.withLock { code = nil }
        onClose?()
    }

    public func redeem(_ attempt: String, now: Date = Date()) -> Bool {
        var closed = false
        let ok: Bool = lock.withLock {
            guard let c = code, now < expires else { return false }
            if DeviceStore.constantTimeEqual(Data(c.utf8), Data(attempt.utf8)) { code = nil; closed = true; return true }
            failures += 1
            if failures >= Self.maxFailures { code = nil; closed = true }
            return false
        }
        if closed { onClose?() }
        return ok
    }
}

/// Which peers may connect: loopback and the Tailscale ranges.
public enum PeerFilter {
    public static func allowed(_ host: String) -> Bool {
        var h = host
        if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }   // IPv6 zone
        if h.hasPrefix("::ffff:") { h = String(h.dropFirst(7)) }
        if h == "127.0.0.1" || h == "::1" || h == "localhost" { return true }
        var v4 = in_addr()
        if inet_pton(AF_INET, h, &v4) == 1 {
            let a = UInt32(bigEndian: v4.s_addr)
            return a & 0xFFC0_0000 == 0x6440_0000   // 100.64.0.0/10
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, h, &v6) == 1 {
            let b = withUnsafeBytes(of: v6) { Array($0) }
            return b[0...5] == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]   // fd7a:115c:a1e0::/48
        }
        return false
    }
}

public enum TailscaleAddresses {
    /// This Mac's addresses inside the tailnet (IPv4 first).
    public static func current() -> [String] {
        var out: [String] = []
        var ifa: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifa) == 0, let first = ifa else { return [] }
        defer { freeifaddrs(ifa) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            guard let sa = cur.pointee.ifa_addr else { continue }
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let len = socklen_t(sa.pointee.sa_family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard sa.pointee.sa_family == AF_INET || sa.pointee.sa_family == AF_INET6,
                  getnameinfo(sa, len, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let s = String(cString: buf)
            if s != "127.0.0.1", s != "::1", PeerFilter.allowed(s), !out.contains(s) { out.append(s) }
        }
        return out.sorted { !$0.contains(":") && $1.contains(":") }
    }

    /// The MagicDNS name of this Mac, e.g. "rashids-mac.tail1234.ts.net", if the CLI knows it.
    public static func magicDNSName() -> String? {
        for path in ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale",
                     "/Applications/Tailscale.app/Contents/MacOS/Tailscale"] where FileManager.default.isExecutableFile(atPath: path) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["status", "--self", "--json"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let me = obj["Self"] as? [String: Any], let name = me["DNSName"] as? String, !name.isEmpty {
                return name.hasSuffix(".") ? String(name.dropLast()) : name
            }
        }
        return nil
    }
}
