import Foundation

/// The JSON files of one character: `<support>/buddy/<character>/{life,mind,memory}.json`.
/// Written with defaults on first use; the user edits them, and they are re-read when they change.
public struct BuddyFiles: Sendable {
    public let dir: URL
    public init(character: String, root: URL = Paths.support.appendingPathComponent("buddy")) {
        dir = root.appendingPathComponent(character)
    }
    public var life: URL { dir.appendingPathComponent("life.json") }
    public var mind: URL { dir.appendingPathComponent("mind.json") }
    public var memory: URL { dir.appendingPathComponent("memory.json") }

    public struct Loaded<T> { public var value: T; public var error: String?; public var modified: Date? }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    public static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    /// Reads `url`; creates it from `fallback` when missing. A broken file keeps `fallback` and reports why,
    /// and is left untouched so the user can fix it.
    public func load<T: Codable>(_ url: URL, fallback: T) -> Loaded<T> {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        guard fm.fileExists(atPath: url.path) else {
            save(fallback, to: url)
            return Loaded(value: fallback, error: nil, modified: Self.modified(url))
        }
        do {
            let data = try Data(contentsOf: url)
            return Loaded(value: try Self.decoder().decode(T.self, from: data), error: nil, modified: Self.modified(url))
        } catch {
            return Loaded(value: fallback, error: "\(url.lastPathComponent): \(Self.describe(error))", modified: Self.modified(url))
        }
    }

    @discardableResult
    public func save<T: Codable>(_ value: T, to url: URL) -> Bool {
        guard let data = try? Self.encoder().encode(value) else { return false }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    static func describe(_ e: Error) -> String {
        if let d = e as? DecodingError {
            switch d {
            case .keyNotFound(let k, _): return "missing “\(k.stringValue)”"
            case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c):
                let path = c.codingPath.map(\.stringValue).joined(separator: ".")
                return path.isEmpty ? c.debugDescription : "\(path): \(c.debugDescription)"
            @unknown default: return "not valid"
            }
        }
        return e.localizedDescription
    }
}
