import Foundation

/// The version of what the Mac and the iPhone app say to each other. Both builds link this file, so each knows
/// its own number; the phone sends its number with every request (`ClientInfo`) and the Mac reports its own in
/// `BridgeStatus.protocolVersion`. Neither side refuses the other over it: it only drives the "update" hints.
///
/// Bump rules:
/// - Bump `current` when one side starts relying on something the other only has from this version on: an endpoint
///   or WebSocket message the phone needs, a field whose absence leaves a feature dead, a changed meaning.
/// - Don't bump for additions the other side can safely ignore.
/// - Either way, new fields stay optional (`decodeIfPresent`, or `Optional` with synthesized `Codable`) and unknown
///   messages are skipped, so a mismatched pair keeps working with what both understand.
/// - Note each bump in the history below.
///
/// History:
/// - 1: everything before versions were sent. A peer that sends no number is treated as 1.
/// - 2: phones send `ClientInfo` headers; Macs report `protocolVersion`; Live Activity content may carry `offline`.
public enum WireProtocol {
    public static let current = 2
    /// What a peer that says nothing about its version is taken to speak.
    public static let unversioned = 1

    /// Which side should be updated, if either.
    public enum Hint: String, Sendable, Equatable {
        /// The phone is older than the Mac: "Update Session Watch on this iPhone" / "… from TestFlight".
        case updatePhone
        /// The Mac is older than the phone: "Update Session Watch on the Mac".
        case updateMac
    }

    /// The older side should catch up. Nil when both speak the same version.
    public static func hint(phone: Int?, mac: Int?) -> Hint? {
        let p = phone ?? unversioned, m = mac ?? unversioned
        if p < m { return .updatePhone }
        if m < p { return .updateMac }
        return nil
    }
}

/// Which build of the iPhone app is talking. Sent as HTTP headers on every request (pairing, the stream upgrade and
/// REST calls alike), so it needs no new endpoint and survives the relay. Older phones send none.
public struct ClientInfo: Codable, Hashable, Sendable {
    public var appVersion: String?      // CFBundleShortVersionString, "1.3"
    public var build: String?           // CFBundleVersion, "202610080636"
    public var protocolVersion: Int?

    public enum Header {
        public static let version = "X-Session-Watch-Version"
        public static let build = "X-Session-Watch-Build"
        public static let proto = "X-Session-Watch-Protocol"
    }

    public init(appVersion: String?, build: String?, protocolVersion: Int? = WireProtocol.current) {
        self.appVersion = appVersion; self.build = build; self.protocolVersion = protocolVersion
    }

    /// From request headers (any case). Nil when the phone sent none of them.
    public init?(headers: [String: String]) {
        var lower: [String: String] = [:]
        for (k, v) in headers { lower[k.lowercased()] = v.trimmingCharacters(in: .whitespaces) }
        func value(_ name: String) -> String? {
            lower[name.lowercased()].flatMap { $0.isEmpty ? nil : String($0.prefix(40)) }
        }
        let v = value(Header.version), b = value(Header.build), p = value(Header.proto).flatMap(Int.init)
        guard v != nil || b != nil || p != nil else { return nil }
        self.init(appVersion: v, build: b, protocolVersion: p)
    }

    /// The headers to send.
    public var headers: [String: String] {
        var h: [String: String] = [:]
        if let appVersion { h[Header.version] = appVersion }
        if let build { h[Header.build] = build }
        if let protocolVersion { h[Header.proto] = String(protocolVersion) }
        return h
    }

    /// "1.3 (202610080636)".
    public var label: String {
        switch (appVersion, build) {
        case let (v?, b?): "\(v) (\(b))"
        case let (v?, nil): v
        case let (nil, b?): "build \(b)"
        case (nil, nil): "unknown version"
        }
    }

    /// What this phone is missing compared with a Mac speaking `macProtocol`, if anything.
    public func hint(macProtocol: Int = WireProtocol.current) -> WireProtocol.Hint? {
        WireProtocol.hint(phone: protocolVersion, mac: macProtocol)
    }
}
