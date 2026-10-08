import SwiftUI
import UserNotifications
import WatchProtocol

@main
struct ClaudeRemoteApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(delegate.store)
                .environment(delegate.lock)
                .tint(Theme.clay)
        }
    }
}

/// Owns the store (so push callbacks and notification actions can reach it) and handles push registration.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// `-demo` (a launch argument, e.g. in the scheme or `simctl launch … -demo`) shows the preview fixtures
    /// without a Mac: for screenshots and trying the UI.
    /// `-demo-pairing` shows the pairing screen the same way.
    static let isDemo = ProcessInfo.processInfo.arguments.contains("-demo") || isDemoPairing
    static let isDemoPairing = ProcessInfo.processInfo.arguments.contains("-demo-pairing")

    let store = isDemoPairing ? RemoteStore(preview: nil, connection: .offline)
        : isDemo ? demoStore() : RemoteStore()
    let lock = isDemo ? AppLock(previewEnabled: false, locked: demo("demoLock") != nil) : AppLock()

    /// Demo knobs, for screenshots of every state (launch arguments such as `-demoState offline` land in
    /// UserDefaults): `demoState` offline | reconnecting | waiting | empty | busy, `demoToast` ok | error,
    /// `demoOpen` chat:<id> | account:<id>, `demoTab` accounts | mac, `demoLock` 1.
    static func demo(_ key: String) -> String? {
        isDemo ? UserDefaults.standard.string(forKey: key) : nil
    }

    private static func demoStore() -> RemoteStore {
        let store: RemoteStore = switch demo("demoState") {
        case "offline": RemoteStore(preview: Fixtures.snapshot, connection: .offline, messages: Fixtures.messages)
        case "reconnecting": RemoteStore(preview: Fixtures.snapshot, connection: .reconnecting, messages: Fixtures.messages)
        case "waiting": RemoteStore(preview: nil, connection: .connecting, paired: true)
        case "empty": RemoteStore(preview: Fixtures.emptySnapshot)
        case "busy": RemoteStore(preview: Fixtures.busySnapshot, messages: Fixtures.messages)
        default: RemoteStore(preview: Fixtures.snapshot, messages: Fixtures.messages)
        }
        switch demo("demoToast") {
        case "ok": store.toast = Toast(message: "allowed · Bash", isError: false)
        case "error": store.toast = Toast(message: "Couldn't reach your Mac: the request timed out.", isError: true)
        default: break
        }
        if demo("demoLive") != nil {   // shows the Live Activity with the fixtures, for screenshots
            store.live.start()
            store.live.update(Fixtures.snapshot, macName: "MacBook Pro")
        }
        if let open = demo("demoOpen") {
            if open.hasPrefix("chat:") { store.deepLink = .chat(String(open.dropFirst(5))) }
            if open.hasPrefix("account:") { store.deepLink = .account(String(open.dropFirst(8))) }
        }
        return store
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Theme.applyAppearance()
        UNUserNotificationCenter.current().delegate = self
        Notifications.registerCategories()
        if !Self.isDemo { store.live.registerBackgroundRefresh() }
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        if !Self.isDemo { store.live.scheduleRefresh() }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        store.didReceivePushToken(Notifications.hex(deviceToken))
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Expected in the Simulator and without a push entitlement; the app works without push.
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let chatId = info["chatId"] as? String
        let promptId = info["promptId"] as? String
        let profileId = info["profileId"] as? String
        let action = response.actionIdentifier

        switch action {
        case Notifications.Action.allow, Notifications.Action.always, Notifications.Action.deny:
            // The same command PromptCard sends; may run with the app launched in the background, no UI.
            guard let chatId, let promptId, let decision = Notifications.decision(for: action) else { return }
            _ = await Notifications.runInBackground(.answer(chatId: chatId, promptId: promptId, decision: decision),
                                                    chatId: chatId)
        case Notifications.Action.cont:
            guard let chatId else { return }
            _ = await Notifications.runInBackground(.reply(chatId: chatId, text: "continue"), chatId: chatId)
        default:   // OPEN or a tap on the notification
            await MainActor.run {
                if let chatId { store.deepLink = .chat(chatId) } else if let profileId { store.deepLink = .account(profileId) }
            }
        }
    }
}
