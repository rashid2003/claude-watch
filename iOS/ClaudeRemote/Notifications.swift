import UIKit
import UserNotifications
import WatchProtocol

/// Push setup and the notification actions (Allow / Always / Deny / Continue run in the background).
enum Notifications {
    enum Category {
        static let prompt = PushCategory.prompt
        static let promptAlways = PushCategory.promptAlways
        static let promptShell = PushCategory.promptShell
        static let promptShellAlways = PushCategory.promptShellAlways
        static let chat = PushCategory.chat
        static let account = PushCategory.account
    }

    enum Action {
        static let allow = "ALLOW"
        static let always = "ALWAYS"
        static let deny = "DENY"
        static let cont = "CONTINUE"
        static let open = "OPEN"
    }

    /// The answer a prompt action stands for; nil for actions that aren't answers.
    static func decision(for action: String) -> PromptDecision? {
        switch action {
        case Action.allow: .allow
        case Action.always: .allowAlways
        case Action.deny: .deny
        default: nil
        }
    }

    /// Allow / Always can run from the Lock Screen, so they need the phone unlocked. With the app lock on,
    /// shell commands get no Allow here: the app asks for Face ID again before allowing one, so they open it.
    static func registerCategories(appLock: Bool = AppLock.isEnabledSetting) {
        let open = UNNotificationAction(identifier: Action.open, title: "Open", options: [.foreground])
        let allow = UNNotificationAction(identifier: Action.allow, title: "Allow", options: [.authenticationRequired])
        let always = UNNotificationAction(identifier: Action.always, title: "Always Allow",
                                          options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: Action.deny, title: "Deny", options: [.destructive])
        let cont = UNNotificationAction(identifier: Action.cont, title: "Continue", options: [])
        let answer = [allow, deny, open], answerAlways = [allow, always, deny, open]
        func category(_ id: String, _ actions: [UNNotificationAction]) -> UNNotificationCategory {
            UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [])
        }
        UNUserNotificationCenter.current().setNotificationCategories([
            category(Category.prompt, answer),
            category(Category.promptAlways, answerAlways),
            category(Category.promptShell, appLock ? [deny, open] : answer),
            category(Category.promptShellAlways, appLock ? [deny, open] : answerAlways),
            category(Category.chat, [cont, open]),
            category(Category.account, [open]),
        ])
    }

    /// Asks once; registers with APNs whenever notifications are allowed.
    @MainActor
    static func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        let settings = await center.notificationSettings()
        if granted || settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    static func hex(_ token: Data) -> String { token.map { String(format: "%02x", $0) }.joined() }

    /// A notification action gets about 30 s in the background; give up well before that.
    static let budget: Duration = .seconds(25)

    /// Runs a notification action against the Mac without the UI, inside a background task: the pairing from
    /// the Keychain, a POST through `RemoteClient` (its usual relay / direct order), then a wait for the job.
    /// Returns false when it didn't get through; a local notification then says so and opens the chat.
    static func runInBackground(_ c: RemoteCommand, chatId: String?) async -> Bool {
        let task = await BackgroundTask(name: c.label)
        let reached = Reached()
        let failure = await withTaskGroup(of: String?.self) { group in
            group.addTask { await send(c, reached) }
            group.addTask {
                try? await Task.sleep(for: budget)
                // Still running once the Mac has the command is fine: it carries on without us.
                return Task.isCancelled || reached.value ? nil : "Your Mac didn't answer in time."
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        if let failure {
            await postLocal(title: "\(c.label) didn't reach your Mac", body: failure + " Open the chat to answer there.",
                            chatId: chatId)
        }
        await task.end()
        return failure == nil
    }

    /// POST, then re-read the job until it's final. Nil when it went through, otherwise why not.
    private static func send(_ c: RemoteCommand, _ reached: Reached) async -> String? {
        guard let creds = Keychain.load() else { return "This iPhone isn't paired with a Mac." }
        let client = RemoteClient(credentials: creds)
        do {
            var job = try await client.perform(c)
            reached.value = true
            while !job.status.isFinal {
                try await Task.sleep(for: .seconds(1))
                job = try await client.perform(c)   // same requestId: reports the job, doesn't rerun it
            }
            return job.status == .done ? nil : job.reason ?? "The Mac couldn't do it."
        } catch {
            // Losing the Mac while re-reading a job it already took isn't a failure.
            return reached.value || error is CancellationError ? nil : error.localizedDescription
        }
    }

    /// Set once the Mac has accepted the command.
    private final class Reached: @unchecked Sendable {
        private let lock = NSLock()
        private var reached = false
        var value: Bool {
            get { lock.withLock { reached } }
            set { lock.withLock { reached = newValue } }
        }
    }

    static func postLocal(title: String, body: String, chatId: String?) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Category.account
        if let chatId { content.userInfo = ["chatId": chatId] }
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
    }
}

/// Keeps the app running while a notification action finishes, and ends cleanly if iOS calls time.
@MainActor
final class BackgroundTask {
    private var id = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in self?.end() }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
