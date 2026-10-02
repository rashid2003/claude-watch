import SwiftUI
import UIKit
import WatchProtocol

struct RootView: View {
    @Environment(RemoteStore.self) private var store
    @Environment(AppLock.self) private var lock
    @Environment(\.scenePhase) private var phase
    @State private var tab: AppTab = switch AppDelegate.demo("demoTab") {
        case "accounts": .accounts
        case "mac": .mac
        default: .chats
    }
    @State private var chatsPath = NavigationPath()
    @State private var accountsPath = NavigationPath()
    @State private var macPath = NavigationPath()
    @State private var scrollToTop: [AppTab: Int] = [:]
    @State private var showNewChat = false
    @State private var keyboardUp = false
    @State private var limitedSeen: Set<String> = []
    @State private var recovered: Set<String> = []

    var body: some View {
        ZStack {
            if store.isPaired {
                tabs
            } else {
                PairingView()
            }
            if lock.isLocked && store.isPaired {
                LockView()
                    .transition(.opacity)
            }
        }
        .animation(.default, value: lock.isLocked)
        .animation(.easeInOut(duration: 0.3), value: store.isPaired)
        .toast()
        .onChange(of: phase, initial: true) { _, p in
            switch p {
            case .active:
                store.start()
                if store.isPaired { Task { await lock.unlock() } }
            case .background:
                lock.lockIfEnabled()
                store.stop()
            default: break
            }
        }
        .onChange(of: store.deepLink, initial: true) { _, link in
            guard let link else { return }
            store.deepLink = nil
            switch link {
            case .chat(let id):
                tab = .chats
                chatsPath = NavigationPath([ChatRoute(id: id)])
            case .account(let id):
                tab = .accounts
                accountsPath = NavigationPath([AccountRoute(profileId: id)])
            }
        }
        .onChange(of: store.isPaired) { _, paired in
            guard paired else { return }
            lock.didPair()   // they just scanned the code (or chose the demo); don't ask for Face ID straight away
            if !store.isDemo { Task { await Notifications.requestAuthorization() } }
        }
        .task {
            if store.isPaired && !AppDelegate.isDemo && !store.isDemo { await Notifications.requestAuthorization() }
        }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            NavigationStack(path: $chatsPath) {
                ChatsView(scrollToTop: scrollToTop[.chats] ?? 0)
                    .navigationDestination(for: ChatRoute.self) { ChatView(chatId: $0.id) }
            }
            .toolbar(.hidden, for: .tabBar)
            .tag(AppTab.chats)

            NavigationStack(path: $accountsPath) {
                AccountsView(scrollToTop: scrollToTop[.accounts] ?? 0)
                    .navigationDestination(for: AccountRoute.self) { AccountDetailView(profileId: $0.profileId) }
                    .navigationDestination(for: ChatRoute.self) { ChatView(chatId: $0.id) }
            }
            .toolbar(.hidden, for: .tabBar)
            .tag(AppTab.accounts)

            NavigationStack(path: $macPath) {
                MacView(scrollToTop: scrollToTop[.mac] ?? 0)
            }
            .toolbar(.hidden, for: .tabBar)
            .tag(AppTab.mac)
        }
        // An overlay, not a safe-area inset: TabView doesn't hand that inset on to the scroll views in its
        // tabs, so each tab's root screen reserves the room itself with `dockClearance()`.
        .overlay(alignment: .bottom) {
            if showBar {
                BottomBar(selection: $tab, recoveredAccounts: recovered,
                          onReselect: reselect, onNewChat: { showNewChat = true })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showBar)
        .sheet(isPresented: $showNewChat) { NewChatView() }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardUp = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardUp = false
        }
        .onChange(of: limitedIds, initial: true) { old, now in
            // An account that was limited and is now free gets a green dot until Accounts is opened.
            let freed = limitedSeen.subtracting(now).filter { id in
                store.snapshot?.accounts.first { $0.id == id }?.state == .free
            }
            recovered.formUnion(freed)
            recovered.subtract(now)
            limitedSeen = now
        }
        .onChange(of: tab) { _, t in
            if t == .accounts { recovered = [] }
        }
    }

    /// Hidden inside a chat (it has its own composer) and while typing.
    private var showBar: Bool { store.openChatId == nil && !keyboardUp }

    private var limitedIds: Set<String> {
        Set(store.snapshot?.accounts.filter { $0.state == .limited }.map(\.id) ?? [])
    }

    /// Tapping the current tab pops to its root, or scrolls to the top when already there.
    private func reselect(_ t: AppTab) {
        switch t {
        case .chats where !chatsPath.isEmpty: chatsPath = NavigationPath()
        case .accounts where !accountsPath.isEmpty: accountsPath = NavigationPath()
        case .mac where !macPath.isEmpty: macPath = NavigationPath()
        default: scrollToTop[t, default: 0] += 1
        }
    }
}

struct ChatRoute: Hashable { let id: String }
struct AccountRoute: Hashable { let profileId: String }

struct LockView: View {
    @Environment(AppLock.self) private var lock

    var body: some View {
        VStack(spacing: 14) {
            Text("✻")
                .font(.system(size: 44, weight: .regular, design: .monospaced))
                .foregroundStyle(Theme.clay)
                .accessibilityHidden(true)
            Text("claude-remote").font(Theme.monoTitle)
            Text("locked · face id required").font(Theme.monoSmall).foregroundStyle(.secondary)
            Button("unlock") { Task { await lock.unlock() } }
                .buttonStyle(.clay)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
    }
}

#Preview("Tabs") {
    RootView()
        .environment(RemoteStore(preview: Fixtures.snapshot))
        .environment(AppLock(previewEnabled: false))
        .tint(Theme.clay)
}
