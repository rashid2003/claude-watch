import Foundation
import WatchProtocol

/// One command for the Mac, encoded once so a resend carries the same `requestId` (the bridge then
/// returns the original job instead of running it twice — which is also how a job's status is re-read).
struct RemoteCommand: Sendable {
    let path: String
    let body: Data
    let requestId: String
    /// What the UI shows as pending, e.g. "reply:local_123". Several commands may share a key.
    let key: String
    let label: String

    private init<B: Encodable>(_ path: String, _ body: B, requestId: String, key: String, label: String) {
        self.path = path
        self.body = (try? WireCoder.encoder.encode(body)) ?? Data("{}".utf8)
        self.requestId = requestId
        self.key = key
        self.label = label
    }

    private static func seg(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? s
    }

    static func reply(chatId: String, text: String) -> RemoteCommand {
        let b = ReplyBody(text: text)
        return .init("/v1/chats/\(seg(chatId))/reply", b, requestId: b.requestId, key: Keys.reply(chatId), label: "Reply")
    }

    static func cancelReply(id: String) -> RemoteCommand {
        let b = PlainCommand()
        return .init("/v1/replies/\(seg(id))/cancel", b, requestId: b.requestId, key: Keys.queued(id), label: "Remove")
    }

    static func sendNow(id: String) -> RemoteCommand {
        let b = PlainCommand()
        return .init("/v1/replies/\(seg(id))/send-now", b, requestId: b.requestId, key: Keys.queued(id), label: "Send now")
    }

    static func answer(chatId: String, promptId: String, decision: PromptDecision) -> RemoteCommand {
        let b = PromptAnswerBody(promptId: promptId, decision: decision)
        return .init("/v1/chats/\(seg(chatId))/prompt", b, requestId: b.requestId, key: Keys.prompt(promptId),
                     label: decision == .deny ? "Deny" : decision == .allowAlways ? "Always allow" : "Allow")
    }

    static func stop(chatId: String) -> RemoteCommand {
        let b = PlainCommand()
        return .init("/v1/chats/\(seg(chatId))/stop", b, requestId: b.requestId, key: Keys.stop(chatId), label: "Stop")
    }

    static func newChat(profileId: String, cwd: String, prompt: String, trust: Bool,
                        target: NewChatTarget = .desktop) -> RemoteCommand {
        let b = NewChatBody(profileId: profileId, cwd: cwd, prompt: prompt, trust: trust ? true : nil, target: target)
        return .init("/v1/chats/new", b, requestId: b.requestId, key: Keys.newChat, label: "New chat")
    }

    static func retry(itemId: String) -> RemoteCommand {
        let b = PlainCommand()
        return .init("/v1/queue/\(seg(itemId))/retry", b, requestId: b.requestId, key: Keys.queue(itemId), label: "Retry")
    }

    static func cancelRetry(itemId: String) -> RemoteCommand {
        let b = PlainCommand()
        return .init("/v1/queue/\(seg(itemId))/cancel", b, requestId: b.requestId, key: Keys.queue(itemId), label: "Cancel retry")
    }

    static func setMode(profileId: String, mode: RetryMode) -> RemoteCommand {
        let b = ModeBody(mode: mode)
        return .init("/v1/accounts/\(seg(profileId))/mode", b, requestId: b.requestId, key: Keys.mode(profileId), label: "Retry mode")
    }

    static func move(sessionId: String, toLocationId: String) -> RemoteCommand {
        let b = MoveBody(sessionId: sessionId, toLocationId: toLocationId)
        return .init("/v1/moves", b, requestId: b.requestId, key: Keys.moveChat(sessionId), label: "Move")
    }

    static func undoMove(id: String) -> RemoteCommand {
        let b = PlainCommand()
        return .init("/v1/moves/\(seg(id))/undo", b, requestId: b.requestId, key: Keys.move(id), label: "Undo move")
    }

    static func cancelMove(id: String) -> RemoteCommand {
        let b = PlainCommand()
        return .init("/v1/moves/\(seg(id))/cancel", b, requestId: b.requestId, key: Keys.move(id), label: "Cancel move")
    }

    static func quitApp(_ app: AppUsage) -> RemoteCommand {
        let b = QuitAppBody(appId: app.id)
        return .init("/v1/system/apps/quit", b, requestId: b.requestId, key: Keys.app(app.id), label: "Quit \(app.name)")
    }

    static func kill(_ app: AppUsage) -> RemoteCommand {
        let b = KillBody(pid: app.mainPid)
        return .init("/v1/system/processes/kill", b, requestId: b.requestId, key: Keys.app(app.id), label: "Kill \(app.name)")
    }

    static func closeIdleClaude() -> RemoteCommand {
        let b = PlainCommand()
        return .init("/v1/system/claude/close-idle", b, requestId: b.requestId, key: Keys.closeIdle, label: "Close idle Claude")
    }

    static func cleanDisk(_ ids: [String]) -> RemoteCommand {
        let b = CleanBody(targets: ids)
        return .init("/v1/system/disk/clean", b, requestId: b.requestId, key: Keys.clean, label: "Free disk")
    }

    static func setAutoAct(_ on: Bool) -> RemoteCommand {
        let b = AutoActBody(enabled: on)
        return .init("/v1/system/auto", b, requestId: b.requestId, key: Keys.autoAct, label: "Auto-act")
    }

    static func restartMoves() -> RemoteCommand {
        let b = PlainCommand()
        return .init("/v1/moves/restart", b, requestId: b.requestId, key: Keys.restart, label: "Restart windows")
    }
}

/// Pending-state keys, so views can ask "is anything for this chat in flight?".
enum Keys {
    static func reply(_ chat: String) -> String { "reply:" + chat }
    static func stop(_ chat: String) -> String { "stop:" + chat }
    static func queued(_ id: String) -> String { "queued:" + id }
    static func prompt(_ id: String) -> String { "prompt:" + id }
    static func queue(_ id: String) -> String { "queue:" + id }
    static func mode(_ profile: String) -> String { "mode:" + profile }
    static func moveChat(_ session: String) -> String { "movechat:" + session }
    static func move(_ id: String) -> String { "move:" + id }
    static let newChat = "newchat"
    static let restart = "restart"
    static func app(_ id: String) -> String { "app:" + id }
    static let closeIdle = "closeidle"
    static let clean = "clean"
    static let autoAct = "autoact"
}
