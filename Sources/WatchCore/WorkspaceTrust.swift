import Foundation

/// Claude Code's folder trust ("Trust this workspace?"), as recorded in `~/.claude.json` and shared by
/// every desktop profile and the CLI. A folder is trusted when it or any folder above it was accepted.
public enum WorkspaceTrust {
    /// `.claude.json` next to the config dir when `CLAUDE_CONFIG_DIR` is set, else in the home folder.
    public static var configFile: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir).appendingPathComponent(".claude.json")
        }
        return Paths.home.appendingPathComponent(".claude.json")
    }

    public static func isTrusted(_ path: String) -> Bool {
        isTrusted(path, accepted: acceptedFolders(), realPath: realPath(path))
    }

    /// Folders whose trust prompt was accepted.
    public static func acceptedFolders(file: URL = configFile) -> Set<String> {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = json["projects"] as? [String: Any] else { return [] }
        return Set(projects.compactMap { key, value in
            ((value as? [String: Any])?["hasTrustDialogAccepted"] as? Bool) == true ? normalize(key) : nil
        })
    }

    public static func isTrusted(_ path: String, accepted: Set<String>) -> Bool {
        isTrusted(path, accepted: accepted, realPath: realPath(path))
    }

    /// Pure check: `path` (or its resolved form) or one of its parents is in `accepted`.
    static func isTrusted(_ path: String, accepted: Set<String>, realPath: String?) -> Bool {
        guard path.hasPrefix("/") else { return false }
        for start in [path, realPath].compactMap({ $0 }) {
            var p = normalize(start)
            while true {
                if accepted.contains(p) { return true }
                if p == "/" { break }
                p = (p as NSString).deletingLastPathComponent
                if p.isEmpty { p = "/" }
            }
        }
        return false
    }

    static func normalize(_ path: String) -> String {
        let s = (path.precomposedStringWithCanonicalMapping as NSString).standardizingPath
        return s.count > 1 && s.hasSuffix("/") ? String(s.dropLast()) : s
    }

    static func realPath(_ path: String) -> String? {
        guard let r = realpath(path, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }
}
