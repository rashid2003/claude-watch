import Foundation
import WatchProtocol

/// The last snapshot on disk (Application Support), so the app opens instantly with something to show.
enum SnapshotCache {
    struct Entry: Codable {
        var receivedAt: Date
        var snapshot: Snapshot
    }

    private static var url: URL? {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true) else { return nil }
        return dir.appending(path: "last-snapshot.json")
    }

    static func load() -> Entry? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? WireCoder.decoder.decode(Entry.self, from: data)
    }

    static func save(_ snapshot: Snapshot, receivedAt: Date) {
        guard let url, let data = try? WireCoder.encoder.encode(Entry(receivedAt: receivedAt, snapshot: snapshot)) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func clear() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
