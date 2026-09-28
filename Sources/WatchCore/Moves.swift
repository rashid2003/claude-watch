import Foundation

/// Pending and finished chat moves, shared by the app and the CLI through `moves.json`.
/// Every change happens under an exclusive lock on `moves.json.lock`.
public final class MoveStore {
    public let url: URL
    public let roots: MoverRoots
    static let keepFinished = 200

    public init(url: URL = Paths.support.appendingPathComponent("moves.json"), roots: MoverRoots = .live) {
        self.url = url
        self.roots = roots
    }

    struct File: Codable { var moves: [PendingMove] = [] }

    /// Missing file means an empty list; a present but undecodable file is set aside on the next update.
    private enum Loaded { case missing, corrupt, moves([PendingMove]) }

    private func load() -> Loaded {
        guard let data = try? Data(contentsOf: url) else { return .missing }
        guard let f = try? JSONCoder.decoder.decode(File.self, from: data) else { return .corrupt }
        return .moves(f.moves)
    }

    public func all() -> [PendingMove] {
        if case .moves(let m) = load() { return m }
        return []
    }

    public var pending: [PendingMove] { all().filter { $0.status == .pending } }

    @discardableResult
    func update<T>(_ body: (inout [PendingMove]) -> T) -> T {
        let fd = open(url.path + ".lock", O_CREAT | O_RDWR, 0o644)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        var list: [PendingMove] = []
        switch load() {
        case .moves(let m): list = m
        case .missing: break
        case .corrupt:
            let aside = url.deletingLastPathComponent()
                .appendingPathComponent(url.lastPathComponent + ".corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.removeItem(at: aside)
            do { try FileManager.default.moveItem(at: url, to: aside) } catch {
                return body(&list)   // never overwrite a corrupt file we could not set aside
            }
        }
        let result = body(&list)
        let finished = list.filter { $0.status != .pending }
        if finished.count > Self.keepFinished {
            let drop = Set(finished.prefix(finished.count - Self.keepFinished).map(\.id))
            list.removeAll { drop.contains($0.id) }
        }
        if let data = try? JSONCoder.pretty.encode(File(moves: list)) { try? data.write(to: url, options: .atomic) }
        return result
    }

    /// Queues a move. Returns nil if the chat already has one pending.
    @discardableResult
    public func add(sessionId: String, title: String, from: ChatLocation, to: ChatLocation,
                    undoOf: String? = nil, now: Date = Date()) -> PendingMove? {
        update { list in
            guard !list.contains(where: { $0.sessionId == sessionId && $0.status == .pending }) else { return nil }
            let id = "mv-\(Int(now.timeIntervalSince1970))-" + UUID().uuidString.prefix(4).lowercased()
            let m = PendingMove(id: id, sessionId: sessionId, title: title, from: from, to: to,
                                createdAt: now, status: .pending, undoOf: undoOf)
            list.append(m)
            return m
        }
    }

    public func cancel(id: String) {
        update { $0.removeAll { $0.id == id && $0.status == .pending } }
    }

    /// Queues the reverse of a finished move.
    public func undo(moveId: String) -> PendingMove? {
        guard let m = all().first(where: { $0.id == moveId && $0.status == .done }) else { return nil }
        return add(sessionId: m.sessionId, title: m.title, from: m.to, to: m.from, undoOf: m.id)
    }

    /// Runs every pending move whose source and destination windows are both closed and whose
    /// chat has no live CLI process. Returns the moves that finished (done, failed or conflict).
    public func runDue(profiles: [Profile], running: Set<String>, liveSessions: Set<String>,
                       now: Date = Date()) -> [PendingMove] {
        update { list in
            var finished: [PendingMove] = []
            for i in list.indices where list[i].status == .pending {
                let m = list[i]
                guard !running.contains(m.from.profileId), !running.contains(m.to.profileId),
                      !liveSessions.contains(m.sessionId) else { continue }
                do {
                    let r = try SessionMover.execute(sessionId: m.sessionId, from: m.from, to: m.to,
                                                     profiles: profiles, roots: roots, now: now)
                    list[i].status = .done
                    list[i].backupDir = r.backupDir.path
                    list[i].note = r.newCwd.map { "folder moved to " + $0 }
                    if let orig = m.undoOf, let j = list.firstIndex(where: { $0.id == orig }) { list[j].status = .undone }
                } catch let e as MoveError {
                    list[i].status = e.conflict ? .conflict : .failed
                    list[i].note = e.description
                    list[i].backupDir = e.backupDir
                } catch {
                    list[i].status = .failed
                    list[i].note = error.localizedDescription
                }
                list[i].finishedAt = now
                finished.append(list[i])
            }
            return finished
        }
    }
}
