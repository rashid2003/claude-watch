import Foundation

public enum ProfileDiscovery {
    /// Finds the default Claude profile plus every ~/Claude-Profiles/<name> directory,
    /// naming each after the launcher applet that opens it when one exists.
    public static func discover(config: Config) -> [Profile] {
        let fm = FileManager.default
        let launchers = findLaunchers()
        var profiles: [Profile] = []

        if fm.fileExists(atPath: Paths.defaultProfile.appendingPathComponent("claude-code-sessions").path) {
            profiles.append(Profile(id: "default", name: "Claude", dataDir: Paths.defaultProfile,
                                    launcherApp: URL(fileURLWithPath: "/Applications/Claude.app")))
        }
        let dirs = (try? fm.contentsOfDirectory(at: Paths.profilesRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  fm.fileExists(atPath: dir.appendingPathComponent("Local State").path)
                    || fm.fileExists(atPath: dir.appendingPathComponent("config.json").path)
            else { continue }
            let id = dir.lastPathComponent
            let launcher = launchers[id]
            let name = launcher.map { prettyName($0.deletingPathExtension().lastPathComponent) } ?? id
            profiles.append(Profile(id: id, name: name, dataDir: dir, launcherApp: launcher))
        }
        return profiles.compactMap { p in
            var p = p
            if let pc = config.profiles[p.id] {
                if pc.hidden == true { return nil }
                if let n = pc.name, !n.isEmpty { p.name = n }
            }
            return p
        }
    }

    /// Maps a renamed profile's old id (a compatibility symlink) to its current directory name.
    public static func canonicalId(_ id: String) -> String {
        let url = Paths.profilesRoot.appendingPathComponent(id)
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return id }
        return URL(fileURLWithPath: dest, relativeTo: Paths.profilesRoot).standardizedFileURL.lastPathComponent
    }

    static func prettyName(_ s: String) -> String {
        // "Claude 2 - me@example.com (Work)" -> "me@example.com (Work)"
        var s = Substring(s)
        if s.hasPrefix("Claude ") { s = s.dropFirst(7) }
        s = s.drop(while: { $0.isNumber || $0 == " " })
        if s.hasPrefix("- ") { s = s.dropFirst(2) }
        let out = s.replacingOccurrences(of: " - ", with: " · ")
        return out.isEmpty ? "Claude" : out
    }

    /// Maps profile directory name -> applet URL by decompiling small AppleScript launchers.
    static func findLaunchers() -> [String: URL] {
        let fm = FileManager.default
        var candidates: [URL] = []
        for root in [Paths.home.appendingPathComponent("Applications"), URL(fileURLWithPath: "/Applications")] {
            let level1 = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for u in level1 {
                if u.pathExtension == "app" { candidates.append(u) }
                else if u.lastPathComponent.localizedCaseInsensitiveContains("claude") {
                    candidates += ((try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? [])
                        .filter { $0.pathExtension == "app" }
                }
            }
        }
        var map: [String: URL] = [:]
        for app in candidates where app.lastPathComponent.localizedCaseInsensitiveContains("claude") {
            let script = app.appendingPathComponent("Contents/Resources/Scripts/main.scpt")
            guard fm.fileExists(atPath: script.path),
                  let src = Shell.run("/usr/bin/osadecompile", [script.path], timeout: 5)?.out else { continue }
            // The script may mention several paths (e.g. the hidden .engines copy); take the profile.
            for part in src.components(separatedBy: "Claude-Profiles/").dropFirst() {
                let id = String(part.prefix(while: { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }))
                if !id.isEmpty, !id.hasPrefix("."), !id.hasPrefix("_") { map[id] = app; break }
            }
        }
        return map
    }
}
