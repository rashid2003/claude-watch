import UIKit
import UserNotifications
import WatchProtocol

/// Push setup and the notification actions (Allow / Deny / Continue run in the background).
enum Notifications {
    enum Category {
        static let prompt = "PROMPT"
        static let chat = "CHAT"
        static let account = "ACCOUNT"
    }

    enum Action {
        static let allow = "ALLOW"
        static let deny = "DENY"
        static let cont = "CONTINUE"
        static let open = "OPEN"
    }

    static func registerCategories() {
        let open = UNNotificationAction(identifier: Action.open, title: "Open", options: [.foreground])
        let allow = UNNotificationAction(identifier: Action.allow, title: "Allow", options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: Action.deny, title: "Deny", options: [.destructive])
        let cont = UNNotificationAction(identifier: Action.cont, title: "Continue", options: [])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: Category.prompt, actions: [allow, deny, open], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.chat, actions: [cont, open], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.account, actions: [open], intentIdentifiers: []),
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

    /// Runs a notification action against the Mac without the UI: POST, then wait up to 20 s for the job.
    /// Returns false when the Mac couldn't be reached or the job didn't succeed (a local notification says why).
    static func runInBackground(_ c: RemoteCommand, chatId: String?) async -> Bool {
        guard let creds = Keychain.load() else {
            await postLocal(title: "Session Watch isn't paired", body: "Open the app to pair with your Mac.", chatId: chatId)
            return false
        }
        let client = RemoteClient(credentials: creds)
        let deadline = Date().addingTimeInterval(20)
        do {
            var job = try await client.perform(c)
            while !job.status.isFinal && Date() < deadline {
                try? await Task.sleep(for: .seconds(1))
                job = try await client.perform(c)   // same requestId: reports the job, doesn't rerun it
            }
            switch job.status {
            case .done, .accepted, .running:
                return true   // still running after 20 s is fine; the Mac carries on
            case .failed, .blocked:
                await postLocal(title: "\(c.label) didn't go through", body: job.reason ?? "The Mac couldn't do it.", chatId: chatId)
                return false
            }
        } catch RemoteError.server(_, let message) {
            await postLocal(title: "\(c.label) didn't go through", body: message, chatId: chatId)
            return false
        } catch {
            await postLocal(title: "Couldn't reach your Mac", body: "Open to retry.", chatId: chatId)
            return false
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
