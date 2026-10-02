import Foundation
import WatchProtocol

/// Sample data for SwiftUI previews.
enum Fixtures {
    static let now = Date()

    static func profile(_ id: String, _ name: String) -> Profile {
        Profile(id: id, name: name, dataDir: URL(fileURLWithPath: "/Users/rashid/Library/Application Support/Claude-\(id)"))
    }

    static func session(_ id: String, profile: String, title: String, cwd: String, minutesAgo: Double,
                        activity: SessionStatus.Activity, last: TranscriptTail.Last = .assistantDone,
                        tasks: [TaskItem] = [], limit: RateLimitHit? = nil) -> SessionStatus {
        let at = now.addingTimeInterval(-minutesAgo * 60)
        return SessionStatus(
            info: SessionInfo(id: id, cliSessionId: "cli-\(id)", priorCliSessionIds: [], profileId: profile,
                              accountUuid: "acct-\(profile)", title: title, cwd: cwd, model: "claude-opus",
                              permissionMode: "default", lastActivityAt: at, isArchived: false, desktopError: nil,
                              desktopErrorAt: nil, hasPendingPermission: false, folder: "acct-\(profile)/org-1"),
            activity: activity,
            tail: TranscriptTail(last: last, lastAt: at, lastRateLimit: limit, lastSuccessAt: at),
            tasks: tasks, tokens5h: 120_000, tokens7d: 2_400_000)
    }

    static let sessions: [String: [SessionStatus]] = [
        "default": [
            session("local_a1", profile: "default", title: "Mobile remote bridge", cwd: "/Users/rashid/Development/claude-watch",
                    minutesAgo: 1, activity: .working, last: .assistantTool,
                    tasks: [TaskItem(id: "1", subject: "Write server", status: .completed),
                            TaskItem(id: "2", subject: "Run tests", activeForm: "Running swift test", status: .in_progress),
                            TaskItem(id: "3", subject: "Update docs", status: .pending)]),
            session("local_a2", profile: "default", title: "Fix DNS for mail", cwd: "/Users/rashid/Development/infra",
                    minutesAgo: 4, activity: .waiting, last: .assistantTool),
        ],
        "account-1": [
            session("local_b1", profile: "account-1", title: "HMIS demo seed data", cwd: "/Users/rashid/Development/hmis",
                    minutesAgo: 22, activity: .failed, last: .rateLimited,
                    limit: RateLimitHit(at: now.addingTimeInterval(-1300), resetsAt: now.addingTimeInterval(3600),
                                        kind: .fiveHour, text: "5-hour limit reached")),
            session("local_b2", profile: "account-1", title: "Refactor forecaster", cwd: "/Users/rashid/Development/claude-watch",
                    minutesAgo: 180, activity: .idle),
        ],
        "account-2": [
            session("local_c1", profile: "account-2", title: "Landing page copy", cwd: "/Users/rashid/Sites/lajward",
                    minutesAgo: 60 * 26, activity: .idle),
        ],
    ]

    static func account(_ id: String, _ name: String, state: AccountState, five: Double, week: Double,
                        mode: RetryMode = .ui) -> AccountStatus {
        AccountStatus(profile: profile(id, name), memberProfileIds: [id], alsoOpenIn: [], accountUuid: "acct-\(id)",
                      running: state != .offline, pid: 123, state: state,
                      limitedUntil: state == .limited ? now.addingTimeInterval(3600) : nil,
                      limitKind: state == .limited ? .fiveHour : nil,
                      fiveHour: LimitForecast(percent: five, samplePercent: five, sampleAt: now, ratePerHour: 12,
                                              hitsAt: five > 60 && five < 100 ? now.addingTimeInterval(2900) : nil,
                                              resetsAt: now.addingTimeInterval(state == .limited ? 3600 : 7200),
                                              resetsFirst: five < 60),
                      weekly: LimitForecast(percent: week, samplePercent: week, sampleAt: now, ratePerHour: 0.8,
                                            resetsAt: now.addingTimeInterval(3 * 86400), resetsFirst: true),
                      tokens5h: 900_000, tokens7d: 12_000_000, tokensPerHourNow: 140_000,
                      sessions: sessions[id] ?? [], retryMode: mode)
    }

    static let locations: [ChatLocation] = [
        ChatLocation(profileId: "default", accountUuid: "acct-default", orgUuid: "org-1", profileName: "Personal",
                     label: "Personal · Lajward", chatCount: 42),
        ChatLocation(profileId: "account-1", accountUuid: "acct-account-1", orgUuid: "org-1", profileName: "Work",
                     label: "Work · Hamagan", chatCount: 17),
        ChatLocation(profileId: "account-2", accountUuid: "acct-account-2", orgUuid: "org-1", profileName: "Spare",
                     label: "Spare · Personal", chatCount: 3),
    ]

    static let snapshot = Snapshot(
        at: now,
        accounts: [account("default", "Personal", state: .working, five: 64, week: 38),
                   account("account-1", "Work", state: .limited, five: 100, week: 71, mode: .cli),
                   account("account-2", "Spare", state: .free, five: 8, week: 12, mode: .off)],
        queue: [RetryItem(sessionId: "local_b1", cliSessionId: "cli-local_b1", profileId: "account-1",
                          title: "HMIS demo seed data", cwd: "/Users/rashid/Development/hmis",
                          failedAt: now.addingTimeInterval(-1300), resetsAt: now.addingTimeInterval(3600),
                          status: .waiting, attempts: 0, lastAttemptAt: nil, lastMode: nil, note: nil)],
        engineOwner: true, scanning: false,
        moves: [PendingMove(id: "mv1", sessionId: "local_b2", title: "Refactor forecaster", from: locations[1],
                            to: locations[0], createdAt: now.addingTimeInterval(-600), status: .pending,
                            note: "Waiting for the windows to restart"),
                PendingMove(id: "mv0", sessionId: "local_c1", title: "Landing page copy", from: locations[0],
                            to: locations[2], createdAt: now.addingTimeInterval(-86400), status: .done,
                            finishedAt: now.addingTimeInterval(-86000))],
        locations: locations,
        profiles: [profile("default", "Personal"), profile("account-1", "Work"), profile("account-2", "Spare")],
        prompts: [PendingPrompt(id: "p1", chatId: "local_a2", profileId: "default", chatTitle: "Fix DNS for mail",
                                toolName: "Bash", summary: "dig +short MX lajward.dev",
                                detail: "dig +short MX lajward.dev && dig +short TXT _dmarc.lajward.dev",
                                source: .desktop, kind: .permission, at: now.addingTimeInterval(-200),
                                canAllowAlways: true)])

    /// Accounts but no chats, prompts, retries or moves: for the empty states.
    static var emptySnapshot: Snapshot {
        var s = snapshot
        for i in s.accounts.indices { s.accounts[i].sessions = [] }
        s.prompts = []
        s.queue = []
        s.moves = []
        return s
    }

    /// More chats than fit on a screen, with long titles: for scrolling clear of the dock and truncation.
    static var busySnapshot: Snapshot {
        var s = snapshot
        var extra: [SessionStatus] = []
        for i in 1...9 {
            let long = i == 1
            let title: String = long ? "A really long chat title that will not fit on one line of a phone" : "Older chat \(i)"
            let cwd: String = long ? "/Users/rashid/Development/an-extremely-long-project-folder-name"
                : "/Users/rashid/Development/misc"
            extra.append(session("local_x\(i)", profile: "account-2", title: title, cwd: cwd,
                                 minutesAgo: Double(i) * 300, activity: .idle))
        }
        if let i = s.accounts.firstIndex(where: { $0.id == "account-2" }) { s.accounts[i].sessions += extra }
        return s
    }

    static let messages: [ChatMessage] = [
        ChatMessage(id: "m1", kind: .user, at: now.addingTimeInterval(-600), text: "Why is mail bouncing for **lajward.dev**?"),
        ChatMessage(id: "m2", kind: .assistant, at: now.addingTimeInterval(-590),
                    text: "Let me check the `MX` and SPF records first.\n\nI'll start with DNS."),
        ChatMessage(id: "m3", kind: .tool, at: now.addingTimeInterval(-580), text: "Ran dig +short MX lajward.dev",
                    toolName: "Bash", toolOK: true),
        ChatMessage(id: "m4", kind: .tool, at: now.addingTimeInterval(-570), text: "Read /etc/postfix/main.cf",
                    toolName: "Read", toolOK: false),
        ChatMessage(id: "m5", kind: .tool, at: now.addingTimeInterval(-560), text: "Searched relayhost",
                    toolName: "Grep", toolOK: nil),
        ChatMessage(id: "m6", kind: .error, at: now.addingTimeInterval(-550), text: "API Error: overloaded"),
    ]

    static let folders: [FolderSuggestion] = [
        FolderSuggestion(cwd: "/Users/rashid/Development/claude-watch", lastUsedAt: now.addingTimeInterval(-300)),
        FolderSuggestion(cwd: "/Users/rashid/Development/infra", lastUsedAt: now.addingTimeInterval(-7200)),
        FolderSuggestion(cwd: "/Users/rashid/Sites/lajward", lastUsedAt: now.addingTimeInterval(-90000)),
    ]

    static let usage: [UsageSample] = (0..<48).map { i in
        let t = now.addingTimeInterval(Double(i - 48) * 900)
        return UsageSample(t: t, org: "org-1", fiveHour: Double((i * 7) % 100), weekly: 20 + Double(i) * 0.4)
    }
}
