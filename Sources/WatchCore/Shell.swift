import Foundation

enum Shell {
    /// Runs a program and returns stdout (nil on launch failure). Blocking.
    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 10) -> (status: Int32, out: String)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        let reader = DispatchQueue(label: "shell.read")
        let group = DispatchGroup()
        group.enter()
        reader.async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate() }
        _ = group.wait(timeout: .now() + 2)
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

public enum ClaudeProcesses {
    public struct Instance: Sendable { public var pid: Int32; public var dataDir: String? }

    /// Main Claude.app processes, keyed by their --user-data-dir (nil = default profile).
    public static func list() -> [Instance] {
        var out: [Instance] = []
        for pid in Runners.allPids() {
            guard let (args, _) = Runners.procArgs(pid, wantEnv: false), let exe = args.first,
                  exe.hasSuffix(".app/Contents/MacOS/Claude"),
                  !args.contains(where: { $0.hasPrefix("--type=") })   // Electron helpers
            else { continue }
            let dir = args.first { $0.hasPrefix("--user-data-dir=") }.map { String($0.dropFirst(16)) }
            out.append(Instance(pid: pid, dataDir: dir))
        }
        return out
    }

    public static func pid(for profile: Profile, in instances: [Instance]) -> Int32? {
        if profile.isDefault { return instances.first(where: { $0.dataDir == nil })?.pid }
        let want = canonical(profile.dataDir.path)
        return instances.first(where: { $0.dataDir.map { canonical($0) == want } ?? false })?.pid
    }

    /// Resolves symlinks and standardizes, so a window launched through a compatibility link
    /// (e.g. ~/Claude-Profiles/account-1 -> claude-3-…) matches its profile folder.
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
