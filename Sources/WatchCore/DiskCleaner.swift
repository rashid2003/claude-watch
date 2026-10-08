import Foundation

/// Measures and empties the caches "free disk" offers: the Trash, Xcode DerivedData, unavailable
/// simulators, the npm cache and the Homebrew cache.
public struct DiskCleaner {
    public var home: URL
    /// Runs a program: (path, args) → (status, stdout). `Shell.run` in production.
    public var run: (String, [String]) -> (status: Int32, out: String)?

    public static let ids = ["trash", "derivedData", "simulators", "npm", "brew"]
    public static let labels = ["trash": "Trash", "derivedData": "Xcode DerivedData", "simulators": "Unavailable simulators",
                                "npm": "npm cache", "brew": "Homebrew cache"]

    public init(home: URL = Paths.home, run: ((String, [String]) -> (status: Int32, out: String)?)? = nil) {
        self.home = home
        self.run = run ?? { Shell.run($0, $1, timeout: 300) }
    }

    var trash: URL { home.appendingPathComponent(".Trash") }
    var derivedData: URL { home.appendingPathComponent("Library/Developer/Xcode/DerivedData") }
    var npm: URL { home.appendingPathComponent(".npm/_cacache") }
    var brewCache: URL { home.appendingPathComponent("Library/Caches/Homebrew") }
    var simulatorsRoot: URL { home.appendingPathComponent("Library/Developer/CoreSimulator/Devices") }
    var brew: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Each target with its size; missing or empty ones are left out. A Trash that can't be read is -1 (unknown).
    public func measure() -> [CleanTarget] {
        Self.ids.compactMap { id in
            let bytes: Int64
            switch id {
            case "trash":
                guard FileManager.default.fileExists(atPath: trash.path) else { return nil }
                bytes = Self.size(trash) ?? -1
            case "simulators": bytes = unavailableSimulators().compactMap { Self.size($0) }.reduce(0, +)
            case "brew": bytes = brew == nil ? 0 : Self.size(brewCache) ?? 0
            default: bytes = url(id).flatMap(Self.size) ?? 0
            }
            return bytes == 0 ? nil : CleanTarget(id: id, label: Self.labels[id] ?? id, bytes: bytes)
        }
    }

    /// Cleans `ids` in order. `freed` is measured before and after, so it's best effort.
    public func clean(_ ids: [String]) -> (freed: Int64, errors: [String]) {
        var freed: Int64 = 0
        var errors: [String] = []
        let fm = FileManager.default
        for id in ids {
            let before = sizeOf(id)
            switch id {
            case "trash":
                if run("/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty the trash"])?.status != 0 {
                    errors.append("Couldn't empty the Trash (allow Session Watch to control Finder)")
                }
            case "derivedData":
                for child in (try? fm.contentsOfDirectory(at: derivedData, includingPropertiesForKeys: nil)) ?? [] {
                    do { try fm.removeItem(at: child) } catch { errors.append("DerivedData: \(error.localizedDescription)"); break }
                }
            case "npm":
                if fm.fileExists(atPath: npm.path) {
                    do { try fm.removeItem(at: npm) } catch { errors.append("npm cache: \(error.localizedDescription)") }
                }
            case "simulators":
                if run("/usr/bin/xcrun", ["simctl", "delete", "unavailable"])?.status != 0 {
                    errors.append("Couldn't delete unavailable simulators")
                }
            case "brew":
                guard let brew else { errors.append("Homebrew isn't installed"); continue }
                if run(brew, ["cleanup", "-s"])?.status != 0 { errors.append("brew cleanup failed") }
            default:
                errors.append("Unknown target \(id)")
                continue
            }
            if let b = before { freed += max(0, b - (sizeOf(id) ?? 0)) }
        }
        return (freed, errors)
    }

    private func url(_ id: String) -> URL? {
        switch id {
        case "trash": trash
        case "derivedData": derivedData
        case "npm": npm
        case "brew": brewCache
        default: nil
        }
    }

    private func sizeOf(_ id: String) -> Int64? {
        id == "simulators" ? unavailableSimulators().compactMap { Self.size($0) }.reduce(0, +) : url(id).flatMap(Self.size)
    }

    /// Device folders of simulators whose runtime is gone (`simctl list devices unavailable -j`).
    func unavailableSimulators() -> [URL] {
        guard FileManager.default.fileExists(atPath: simulatorsRoot.path),
              let out = run("/usr/bin/xcrun", ["simctl", "list", "devices", "unavailable", "-j"])?.out,
              let json = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let devices = json["devices"] as? [String: [[String: Any]]] else { return [] }
        return devices.values.flatMap { $0 }.compactMap { $0["udid"] as? String }.map { simulatorsRoot.appendingPathComponent($0) }
    }

    /// Allocated size of everything under `url`; nil when it's missing or unreadable.
    static func size(_ url: URL) -> Int64? {
        let fm = FileManager.default
        guard (try? fm.contentsOfDirectory(atPath: url.path)) != nil else { return nil }
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey],
                                    options: [], errorHandler: { _, _ in true }) else { return nil }
        var total: Int64 = 0
        for case let f as URL in e {
            guard let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
