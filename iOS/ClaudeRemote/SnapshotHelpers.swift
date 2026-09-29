import SwiftUI
import WatchProtocol

/// A stable colour per profile id (FNV-1a over the id, so it survives relaunches unlike `hashValue`).
enum AccountColor {
    private static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .yellow, .indigo, .mint, .brown, .red]

    static func color(for profileId: String) -> Color {
        if profileId == "default" { return .blue }
        var h: UInt32 = 2_166_136_261
        for b in profileId.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return palette[Int(h % UInt32(palette.count - 1)) + 1]
    }
}

extension SessionStatus {
    /// The current task's "doing" text, e.g. "Running tests".
    var currentTask: String? {
        tasks.first { $0.status == .in_progress }.map { $0.activeForm ?? $0.subject }
    }

    var isRateLimited: Bool { tail.last == .rateLimited }

    /// Failed on a usage limit — offer a one-tap Continue.
    var canContinue: Bool {
        activity != .working && (tail.last == .rateLimited || (activity == .failed && tail.lastRateLimit != nil))
    }

    var isWorking: Bool { activity == .working }
}

extension Snapshot {
    func session(_ id: String) -> SessionStatus? {
        for a in accounts { if let s = a.sessions.first(where: { $0.id == id }) { return s } }
        return nil
    }

    /// The account a chat belongs to (by its profile), falling back to whichever account lists it.
    func account(for s: SessionStatus) -> AccountStatus? {
        account(forProfile: s.info.profileId) ?? accounts.first { $0.sessions.contains { $0.id == s.id } }
    }

    func accountName(forProfile id: String) -> String {
        account(forProfile: id)?.profile.name ?? profiles.first { $0.id == id }?.name ?? id
    }

    func prompts(forChat id: String) -> [PendingPrompt] {
        prompts.filter { $0.chatId == id }.sorted { $0.at < $1.at }
    }

    /// Where a chat could be moved: every known location except the one its record lives in now.
    func moveDestinations(for s: SessionStatus) -> [ChatLocation] {
        let current = s.info.profileId + "/" + s.info.folder
        return locations.filter { $0.id != current }
    }

    func needsYou(_ s: SessionStatus) -> Bool {
        prompts.contains { $0.chatId == s.id } || s.activity == .waiting || s.activity == .failed || s.isRateLimited
            || s.info.hasPendingPermission
    }
}
