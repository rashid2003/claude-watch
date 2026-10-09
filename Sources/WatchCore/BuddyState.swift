import Foundation
import WatchProtocol

/// What the desktop buddy feels, most urgent first.
public enum BuddyMood: String, CaseIterable, Sendable {
    case needsYou, error, celebrating, busy, sleeping

    public var title: String {
        switch self {
        case .needsYou: "Needs you"
        case .error: "Something broke"
        case .celebrating: "Just finished"
        case .busy: "Working"
        case .sleeping: "Sleeping"
        }
    }
}

/// One chat the buddy can point at.
public struct BuddyChat: Equatable, Sendable, Identifiable {
    public enum Kind: Sendable { case needsYou, error, working, idle }
    public var id: String
    public var profileId: String
    public var title: String
    public var isTerminal: Bool
    /// Every id the chat goes by (desktop id, CLI session ids), to match it to a running `claude`.
    public var sessionIds: [String]
    public var kind: Kind
    /// What it needs, for the speech bubble ("Asks permission", "Hit an error"…).
    public var reason: String
}

public struct BuddyState: Equatable, Sendable {
    public var mood: BuddyMood
    /// The chat a click opens: the first one that needs you, else the first error, else the newest worker.
    public var urgent: BuddyChat?
    public var needsYou: [BuddyChat]
    public var errors: [BuddyChat]
    public var working: [BuddyChat]
    public var recent: [BuddyChat]

    public static let asleep = BuddyState(mood: .sleeping, urgent: nil, needsYou: [], errors: [], working: [], recent: [])
}

/// Turns snapshots into a `BuddyState`. Keeps the last activity per chat so it can tell when a chat
/// has just finished its turn (a short celebration).
public struct BuddyTracker: Sendable {
    public static let celebrationSeconds: TimeInterval = 5

    private var last: [String: SessionStatus.Activity] = [:]
    private var celebratingUntil: Date = .distantPast
    private var celebrated: BuddyChat?
    private var primed = false

    public init() {}

    /// An old error or limit hit no longer worries anyone.
    static let errorFreshness: TimeInterval = 30 * 60

    public static func kind(of s: SessionStatus, prompts: [PendingPrompt], now: Date = Date()) -> (BuddyChat.Kind, String) {
        if let p = prompts.first(where: { $0.chatId == s.id }) { return (.needsYou, p.summary.isEmpty ? "Asks for your answer" : p.summary) }
        if s.info.hasPendingPermission { return (.needsYou, "Asks for permission") }
        if s.activity == .waiting { return (.needsYou, "Waiting for you") }
        let fresh = now.timeIntervalSince(s.info.lastActivityAt) < errorFreshness
        if s.activity == .failed, fresh { return (.error, "Hit an error") }
        if s.tail.last == .rateLimited, fresh { return (.error, "Hit a usage limit") }
        if s.tail.last == .apiError, fresh { return (.error, "API error") }
        if s.activity == .working { return (.working, "Working") }
        return (.idle, "Idle")
    }

    public mutating func update(_ snapshot: Snapshot?, now: Date = Date()) -> BuddyState {
        guard let snapshot else { return .asleep }
        var seen = Set<String>()
        let sessions = snapshot.accounts.flatMap(\.sessions)
            .filter { !$0.info.isArchived && seen.insert($0.id).inserted }
            .sorted { $0.info.lastActivityAt > $1.info.lastActivityAt }
        let chats = sessions.map { s -> BuddyChat in
            let (k, why) = Self.kind(of: s, prompts: snapshot.prompts, now: now)
            return BuddyChat(id: s.id, profileId: s.info.profileId, title: s.info.title.isEmpty ? "Untitled chat" : s.info.title,
                             isTerminal: s.info.isTerminalChat,
                             sessionIds: [s.info.id, s.info.cliSessionId].compactMap { $0 } + s.info.priorCliSessionIds, kind: k, reason: why)
        }
        // A chat that was working and now sits idle just finished.
        if primed {
            for c in chats where c.kind == .idle && last[c.id] == .working {
                celebratingUntil = now.addingTimeInterval(Self.celebrationSeconds)
                celebrated = c
            }
        }
        last = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.activity) })
        primed = true

        let needs = chats.filter { $0.kind == .needsYou }
        let errors = chats.filter { $0.kind == .error }
        let working = chats.filter { $0.kind == .working }
        let mood: BuddyMood
        var urgent: BuddyChat?
        if let n = needs.first { mood = .needsYou; urgent = n }
        else if let e = errors.first { mood = .error; urgent = e }
        else if now < celebratingUntil { mood = .celebrating; urgent = celebrated }
        else if let w = working.first { mood = .busy; urgent = w }
        else { mood = .sleeping; urgent = chats.first }
        return BuddyState(mood: mood, urgent: urgent, needsYou: needs, errors: errors, working: working,
                          recent: Array(chats.prefix(12)))
    }
}
