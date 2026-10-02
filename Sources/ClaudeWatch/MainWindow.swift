import AppKit
import SwiftUI
import WatchCore

/// The "Session Watch" window: a sidebar with Overview, Chats, iPhone and Settings.
struct MainWindow: View {
    static let id = "main"
    @EnvironmentObject var model: WatchModel

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
        } detail: {
            switch model.section ?? .overview {
            case .overview: OverviewView()
            case .chats: ChatsSection()
            case .iphone: ScrollView { PairingWindow(embedded: true) }
            case .settings: SettingsView()
            }
        }
        .navigationTitle("Session Watch")
        .navigationSubtitle((model.section ?? .overview).title)
        .frame(minWidth: 760, minHeight: 480)
        .tint(Theme.clay)
        .capturesOpenWindow(model)
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @EnvironmentObject var model: WatchModel

    var body: some View {
        List(selection: $model.section) {
            ForEach(MainSection.allCases) { sec in
                Label { Text(sec.title).font(Theme.mono) } icon: { Image(systemName: sec.symbol) }
                    .badge(badge(sec))
                    .tag(sec)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { AccountsFooter() }
    }

    func badge(_ sec: MainSection) -> Int {
        guard sec == .chats, let s = model.snapshot else { return 0 }
        return s.allChats.filter { s.needsYou($0) }.count
    }
}

/// Bottom of the sidebar: one line per account with its state and 5-hour use.
private struct AccountsFooter: View {
    @EnvironmentObject var model: WatchModel

    var body: some View {
        if let s = model.snapshot, !s.accounts.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(s.accounts) { a in
                    HStack(spacing: 6) {
                        Circle().fill(Theme.color(a.state)).frame(width: 6, height: 6)
                        Text(AccountName.short(a.profile.name)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 2)
                        Text(a.state == .limited ? "⏸" : Fmt.percent(a.fiveHour.percent)).foregroundStyle(.secondary)
                    }
                    .help("\(a.profile.name): \(Theme.label(a.state)), 5h \(Fmt.percent(a.fiveHour.percent))")
                }
                Text("updated " + Fmt.ago(s.at)).foregroundStyle(.tertiary)
            }
            .font(Theme.monoSmall)
            .padding(12)
        }
    }
}

// MARK: - Shared pieces

/// A rounded panel, like the iPhone app's cards.
struct Panel<Content: View>: View {
    var title: String?
    var count: Int?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.semibold)
                    if let count { Text("\(count)").foregroundStyle(.secondary) }
                }
                .font(Theme.mono)
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

enum AccountName {
    /// "rashid@lajward.dev (Hamagan)" → ("lajward.dev", "Hamagan"): the user part is the same on every card.
    static func split(_ name: String) -> (title: String, org: String?) {
        var title = name
        var org: String?
        if title.hasSuffix(")"), let open = title.lastIndex(of: "(") {
            org = String(title[title.index(after: open)..<title.index(before: title.endIndex)])
            title = String(title[..<open]).trimmingCharacters(in: .whitespaces)
        }
        if let at = title.firstIndex(of: "@") { title = String(title[title.index(after: at)...]) }
        return (title.isEmpty ? name : title, org)
    }

    static func short(_ name: String) -> String {
        let n = split(name)
        return n.org.map { "\(n.title) (\($0))" } ?? n.title
    }
}

extension Snapshot {
    /// Every chat across accounts, once each, newest first.
    var allChats: [SessionStatus] {
        var seen = Set<String>()
        return accounts.flatMap(\.sessions)
            .filter { !$0.info.isArchived && seen.insert($0.id).inserted }
            .sorted { $0.info.lastActivityAt > $1.info.lastActivityAt }
    }

    func account(for s: SessionStatus) -> AccountStatus? {
        accounts.first { $0.memberProfileIds.contains(s.info.profileId) || $0.id == s.info.profileId }
            ?? accounts.first { $0.sessions.contains { $0.id == s.id } }
    }

    func needsYou(_ s: SessionStatus) -> Bool {
        prompts.contains { $0.chatId == s.id } || s.activity == .waiting || s.activity == .failed
            || s.tail.last == .rateLimited || s.info.hasPendingPermission
    }
}

// MARK: - Overview

struct OverviewView: View {
    @EnvironmentObject var model: WatchModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let s = model.snapshot {
                        content(s, now: ctx.date)
                    } else {
                        Text("Reading transcripts… the first run scans the last 7 days.")
                            .font(Theme.mono).foregroundStyle(.secondary).padding(.vertical, 12)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        
        .toolbar { RefreshButton() }
    }

    @ViewBuilder
    func content(_ s: Snapshot, now: Date) -> some View {
        warnings(s)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
            ForEach(s.accounts) { a in
                Panel { AccountCard(a: a, now: now, maxSessions: 8).padding(.vertical, -8) }
            }
        }
        let waitingProfiles = Array(Set(s.queue.filter { $0.status == .waiting }.map(\.profileId)))
        Panel(title: "retry queue", count: s.queue.filter(\.isActive).count) {
            if s.queue.isEmpty {
                Text("Nothing queued. Chats that hit a usage limit are retried here once it resets.")
                    .font(Theme.monoSmall).foregroundStyle(.secondary)
            } else {
                QueueBlock(title: "", queue: s.queue, now: now, showProfile: true, recentLimit: 8,
                           retryAll: { model.retryAll(waitingProfiles) })
            }
        }
        Panel(title: "moves", count: s.moves.filter { $0.status == .pending }.count) {
            PendingMoves()
            RecentMoves().font(Theme.monoSmall)
            if s.moves.isEmpty {
                Text("No moves. Use ⇄ on a chat to move it to another window.")
                    .font(Theme.monoSmall).foregroundStyle(.secondary)
            }
        }
        Panel(title: "retries: ui vs cli") { StatsView() }
    }

    @ViewBuilder
    func warnings(_ s: Snapshot) -> some View {
        if !s.engineOwner {
            Text("Another claude-watch process is running retries.")
                .font(Theme.monoSmall).foregroundStyle(.secondary)
        }
        if s.accounts.contains(where: { $0.retryMode == .ui }) && !model.trusted {
            HStack {
                Text("UI retries need Accessibility access.").foregroundStyle(Theme.yellow)
                Button("Grant") { UIRetry.requestTrust() }.buttonStyle(.link)
            }
            .font(Theme.monoSmall)
        }
    }
}

/// Moves waiting for their windows to restart.
struct PendingMoves: View {
    @EnvironmentObject var model: WatchModel

    var body: some View {
        let pending = (model.snapshot?.moves ?? []).filter { $0.status == .pending }
        if !pending.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(pending) { m in
                    HStack(spacing: 6) {
                        Text("…").foregroundStyle(Theme.clay)
                        Text(m.title).lineLimit(1)
                        Text(m.from.profileName + " → " + m.to.label).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Text("waiting for restart").foregroundStyle(Theme.clay)
                        Button("Restart now") { model.askRestart([m]) }.buttonStyle(.link)
                        Button { model.cancelMove(m.id) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).foregroundStyle(.tertiary).help("Cancel move")
                    }
                }
            }
            .font(Theme.monoSmall)
        }
    }
}

struct RefreshButton: View {
    @EnvironmentObject var model: WatchModel
    var body: some View {
        Button { model.monitor.refreshNow() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            .help("Refresh now")
            .keyboardShortcut("r")
    }
}

// MARK: - Chats

/// Every chat across accounts, grouped by what it needs from you, with the iPhone app's account cards on top.
struct ChatsSection: View {
    @EnvironmentObject var model: WatchModel
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""
    @AppStorage("chats.account") private var accountFilter = ""   // account id; "" = all

    struct Groups {
        var needsYou: [SessionStatus] = []
        var working: [SessionStatus] = []
        var recent: [SessionStatus] = []
        var isEmpty: Bool { needsYou.isEmpty && working.isEmpty && recent.isEmpty }
    }

    func groups(_ snap: Snapshot) -> Groups {
        var g = Groups()
        let q = search.trimmingCharacters(in: .whitespaces)
        for s in snap.allChats {
            if !accountFilter.isEmpty, snap.account(for: s)?.id != accountFilter { continue }
            if !q.isEmpty, !s.info.title.localizedCaseInsensitiveContains(q), !s.info.cwd.localizedCaseInsensitiveContains(q) { continue }
            if snap.needsYou(s) { g.needsYou.append(s) } else if s.activity == .working { g.working.append(s) } else { g.recent.append(s) }
        }
        return g
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let snap = model.snapshot {
                        AccountSwitcher(selection: $accountFilter, snap: snap, now: ctx.date)
                        let g = groups(snap)
                        if g.isEmpty {
                            Text(search.isEmpty ? "No chats yet." : "Nothing matches “\(search)”. Titles and folders are searched.")
                                .font(Theme.mono).foregroundStyle(.secondary).padding(.vertical, 12)
                        }
                        section("needs you", g.needsYou, color: Theme.clay, snap)
                        section("working", g.working, color: Theme.yellow, snap)
                        section("recent", g.recent, color: .secondary, snap)
                    } else {
                        Text("Reading transcripts…").font(Theme.mono).foregroundStyle(.secondary)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        
        .searchable(text: $search, placement: .toolbar, prompt: "search chats")
        .toolbar {
            RefreshButton()
            Button {
                model.chatsProfile = accountFilter.isEmpty ? nil : accountFilter
                openWindow(id: "chats")
            } label: { Label("All chats", systemImage: "list.bullet.rectangle") }
            .help("Every chat of a window, including archived ones, with bulk moves")
        }
        .onChange(of: model.snapshot?.accounts.map(\.id)) { _, ids in
            if !accountFilter.isEmpty, let ids, !ids.contains(accountFilter) { accountFilter = "" }
        }
    }

    @ViewBuilder
    func section(_ title: String, _ rows: [SessionStatus], color: Color, _ snap: Snapshot) -> some View {
        if !rows.isEmpty {
            Panel {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text(title).fontWeight(.semibold)
                    Text("\(rows.count)").foregroundStyle(.secondary)
                }
                .font(Theme.mono)
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(rows) { s in
                        SessionRow(s: s, account: accountFilter.isEmpty ? snap.account(for: s).map { AccountName.short($0.profile.name) } : nil,
                                   lastActive: true) {
                            model.open(sessionId: s.id, profileId: s.info.profileId)
                        }
                    }
                }
            }
        }
    }
}

/// One card per account with its state, 5h / 7d use and chat counts; picking one filters the list.
struct AccountSwitcher: View {
    @Binding var selection: String   // account id; "" = all
    let snap: Snapshot
    let now: Date

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                allCard
                ForEach(snap.accounts) { a in card(a) }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 2)
        }
    }

    var chats: [SessionStatus] { snap.allChats }

    var allCard: some View {
        let limited = snap.accounts.filter { $0.state == .limited }.count
        let working = chats.filter { $0.activity == .working }.count
        return shell(selected: selection.isEmpty, width: 140, action: { selection = "" }) {
            HStack(spacing: 5) {
                Text("✻").foregroundStyle(Theme.clay)
                Text("all").fontWeight(.semibold)
                Spacer(minLength: 0)
                promptMark(snap.prompts.count)
            }
            Text("\(snap.accounts.count) accounts").foregroundStyle(.secondary)
            if limited > 0 { Text("\(limited) limited").foregroundStyle(Theme.red) }
            Spacer(minLength: 0)
            if working > 0 { Text("\(working) working").foregroundStyle(Theme.yellow) }
            Text("\(chats.count) chats").foregroundStyle(.secondary)
        }
    }

    func card(_ a: AccountStatus) -> some View {
        let mine = chats.filter { snap.account(for: $0)?.id == a.id }
        let prompts = snap.prompts.filter { p in a.memberProfileIds.contains(p.profileId) || p.profileId == a.id }.count
        let working = mine.filter { $0.activity == .working }.count
        let name = AccountName.split(a.profile.name)
        return shell(selected: selection == a.id, width: 210, action: { selection = selection == a.id ? "" : a.id }) {
            HStack(spacing: 5) {
                Circle().fill(Theme.color(a.state)).frame(width: 7, height: 7)
                Text(name.title).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                promptMark(prompts)
            }
            HStack(spacing: 0) {
                if let org = name.org { Text(org + " · ").foregroundStyle(.secondary) }
                Text(stateLine(a)).foregroundStyle(Theme.color(a.state)).layoutPriority(1)
            }
            .lineLimit(1)
            bar("5h", a.fiveHour.percent)
            bar("7d", a.weekly.percent)
            Spacer(minLength: 0)
            Text(working > 0 ? "\(working) working · \(mine.count) chats" : "\(mine.count) chats")
                .foregroundStyle(.secondary).lineLimit(1)
        }
        .help(a.profile.name)
    }

    func shell<C: View>(selected: Bool, width: CGFloat, action: @escaping () -> Void, @ViewBuilder _ content: () -> C) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button(action: action) {
            VStack(alignment: .leading, spacing: 4) { content() }
                .font(Theme.monoSmall)
                .padding(10)
                .frame(width: width, alignment: .topLeading)
                .frame(minHeight: 112, maxHeight: .infinity, alignment: .topLeading)
                .background(shape.fill(selected ? Theme.clay.opacity(0.12) : Theme.panel))
                .overlay(shape.strokeBorder(selected ? Theme.clay : Theme.hairline, lineWidth: selected ? 1 : 0.5))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder func promptMark(_ n: Int) -> some View {
        if n > 0 { Text("◆\(n)").fontWeight(.bold).foregroundStyle(Theme.clay).fixedSize() }
    }

    func bar(_ label: String, _ p: Double?) -> some View {
        HStack(spacing: 5) {
            Text(label).foregroundStyle(.secondary).fixedSize()
            UsageBar(percent: p)
            Text(Fmt.percent(p)).fixedSize().frame(minWidth: 34, alignment: .trailing)
        }
    }

    func stateLine(_ a: AccountStatus) -> String {
        var s = Theme.label(a.state)
        if a.state == .limited, let u = a.limitedUntil { s += " · " + Fmt.time(u, now: now) }
        return s
    }
}
