import SwiftUI
import WatchProtocol

/// Every chat of every account, grouped by what it needs from you.
struct ChatsView: View {
    @Environment(RemoteStore.self) private var store
    @State private var search = ""
    @SceneStorage("chats.account") private var accountFilter: String?   // account id; nil = all
    var scrollToTop = 0

    private struct Groups {
        var needsYou: [SessionStatus] = []
        var working: [SessionStatus] = []
        var recent: [SessionStatus] = []
        var isEmpty: Bool { needsYou.isEmpty && working.isEmpty && recent.isEmpty }
    }

    private var groups: Groups {
        guard let snap = store.snapshot else { return Groups() }
        var g = Groups()
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        for s in snap.sessions where !s.info.isArchived {
            if let f = accountFilter, snap.account(for: s)?.id != f, s.info.profileId != f { continue }
            if !q.isEmpty, !s.info.title.lowercased().contains(q), !s.info.cwd.lowercased().contains(q) { continue }
            if snap.needsYou(s) { g.needsYou.append(s) } else if s.isWorking { g.working.append(s) } else { g.recent.append(s) }
        }
        return g
    }

    var body: some View {
        let g = groups
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                StatusStrip(section: filterName.map { "chats · \(AccountSwitcher.shortName($0))" } ?? "chats")
                AccountSwitcher(selection: $accountFilter)
                if store.snapshot == nil {
                    Divider()
                    EmptyNote(text: "Waiting for your Mac… chats appear once ClaudeWatch answers.")
                } else if g.isEmpty {
                    Divider()
                    EmptyNote(text: search.isEmpty ? "No chats yet." : "Nothing matches “\(search)”.")
                }
                section("needs you", g.needsYou, color: Theme.clay)
                section("working", g.working, color: Theme.yellow)
                section("recent", g.recent, color: .secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollToTop(on: scrollToTop)
        .screenBackground()
        .navigationTitle("chats")
        .remoteHeader()
        .searchable(text: $search, prompt: "search chats")
        .refreshable { store.reconnect() }
        .onChange(of: store.snapshot?.accounts.map(\.id)) { _, ids in
            // The chosen account went away (signed out, merged): fall back to all.
            if let f = accountFilter, let ids, !ids.contains(f) { accountFilter = nil }
        }
    }

    private var filterName: String? {
        accountFilter.flatMap { id in store.snapshot?.accounts.first { $0.id == id }?.profile.name }
    }

    @ViewBuilder
    private func section(_ title: String, _ rows: [SessionStatus], color: Color) -> some View {
        if !rows.isEmpty {
            Divider()
            SectionTitle(title: title, count: rows.count) {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            ForEach(rows) { s in
                NavigationLink(value: ChatRoute(id: s.id)) { SessionRowView(session: s, showAccount: accountFilter == nil) }
                    .buttonStyle(.row)
                    .foregroundStyle(.primary)
            }
        }
    }
}

#Preview {
    NavigationStack {
        ChatsView()
            .navigationDestination(for: ChatRoute.self) { ChatView(chatId: $0.id) }
    }
    .environment(RemoteStore(preview: Fixtures.snapshot))
    .environment(AppLock(previewEnabled: false))
    .tint(Theme.clay)
}
