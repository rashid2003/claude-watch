import Darwin
import Foundation

/// A Claude Code CLI process spawned by a desktop instance for one chat.
public struct Runner: Hashable, Sendable {
    public var pid: Int32
    public var dataDir: String       // profile directory the binary lives in
    public var sessionId: String     // desktop local_… id
    public var accountUuid: String?
    public var orgUuid: String?
    /// "account/org": usage limits apply per org membership.
    public var identity: String? { accountUuid.flatMap { a in orgUuid.map { a + "/" + $0 } } }
}

public enum Runners {
    /// Lists desktop-spawned CLI processes. Reads only CLAUDE_CODE_HOST_SESSION_ID,
    /// CLAUDE_CODE_ACCOUNT_UUID and CLAUDE_CODE_ORGANIZATION_UUID; nothing else is kept.
    public static func list() -> [Runner] {
        var out: [Runner] = []
        for pid in allPids() {
            guard let (args, env) = procArgs(pid), let exe = args.first,
                  let r = exe.range(of: "/claude-code/"), exe.hasSuffix("/claude.app/Contents/MacOS/claude")
            else { continue }
            var session: String?, account: String?, org: String?
            for kv in env {
                if kv.hasPrefix("CLAUDE_CODE_HOST_SESSION_ID=") { session = String(kv.dropFirst(28)) }
                else if kv.hasPrefix("CLAUDE_CODE_ACCOUNT_UUID=") { account = String(kv.dropFirst(25)) }
                else if kv.hasPrefix("CLAUDE_CODE_ORGANIZATION_UUID=") { org = String(kv.dropFirst(30)) }
            }
            guard let session, !session.isEmpty else { continue }
            out.append(Runner(pid: pid, dataDir: String(exe[..<r.lowerBound]), sessionId: session, accountUuid: account, orgUuid: org))
        }
        return out
    }

    static func allPids() -> [Int32] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count + 16)
        size = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride).map { $0.kp_proc.p_pid }.filter { $0 > 0 }
    }

    /// argv and environment of a process via KERN_PROCARGS2.
    static func procArgs(_ pid: Int32, wantEnv: Bool = true) -> ([String], [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 8 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        while i < size, buf[i] != 0 { i += 1 }   // exec path
        while i < size, buf[i] == 0 { i += 1 }   // padding
        var strings: [String] = []
        var start = i
        while i < size {
            if buf[i] == 0 {
                if i > start { strings.append(String(decoding: buf[start..<i], as: UTF8.self)) }
                else if strings.count >= argc { break }
                start = i + 1
                if !wantEnv && strings.count >= argc { break }
            }
            i += 1
        }
        guard strings.count >= argc else { return nil }
        return (Array(strings.prefix(argc)), Array(strings.dropFirst(argc)))
    }
}

/// Remembers which profile last ran each chat (chats are mirrored across profiles).
final class Attribution {
    private var map: [String: String] = [:]   // sessionId -> profileId
    private var dirty = false
    private let url = Paths.support.appendingPathComponent("attribution.json")

    init() {
        if let d = try? Data(contentsOf: url), let m = try? JSONDecoder().decode([String: String].self, from: d) {
            map = m.mapValues(ProfileDiscovery.canonicalId)
            dirty = map != m
        }
    }

    func profile(for sessionId: String) -> String? { map[sessionId] }

    func record(_ sessionId: String, profileId: String) {
        if map[sessionId] != profileId { map[sessionId] = profileId; dirty = true }
    }

    func save() {
        guard dirty, let d = try? JSONEncoder().encode(map) else { return }
        try? d.write(to: url, options: .atomic)
        dirty = false
    }
}
