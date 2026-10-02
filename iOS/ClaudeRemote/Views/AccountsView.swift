import SwiftUI
import WatchProtocol

/// Every account like the menu-bar popover, then the retry queue and pending moves.
struct AccountsView: View {
    @Environment(RemoteStore.self) private var store
    var scrollToTop = 0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    StatusStrip(section: "accounts")
                    if let snap = store.snapshot {
                        ForEach(snap.accounts) { a in
                            Divider()
                            AccountRowView(account: a, now: ctx.date)
                        }
                        LiveActivitySection()
                        QueueSection(queue: snap.queue, now: ctx.date)
                        MovesSection(moves: snap.moves)
                        if !snap.engineOwner {
                            Divider()
                            Text("Another claude-watch process is running retries.")
                                .font(Theme.monoSmall).foregroundStyle(.secondary).padding(.vertical, 8)
                        }
                    } else {
                        Divider()
                        EmptyNote(text: "waiting for your mac…", hint: "accounts appear once ClaudeWatch answers", busy: true)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollToTop(on: scrollToTop)
            .dockClearance()
        }
        .screenBackground()
        .navigationTitle("accounts")
        .remoteHeader()
        .refreshable { store.reconnect() }
    }
}

struct QueueSection: View {
    @Environment(RemoteStore.self) private var store
    let queue: [RetryItem]
    let now: Date

    private static let activeStates: [RetryItem.Status] = [.waiting, .running, .verifying]

    var body: some View {
        let active = queue.filter { Self.activeStates.contains($0.status) }
        let recent = Array(queue.filter { !Self.activeStates.contains($0.status) }.suffix(3))
        if !active.isEmpty || !recent.isEmpty {
            Divider()
            SectionTitle(title: "retry queue", count: active.count) { EmptyView() }
            ForEach(active) { it in row(it, mark: "⟳", color: Theme.clay, detail: when(it), active: true) }
            ForEach(recent) { it in
                row(it, mark: it.status == .done ? "✓" : it.status == .failed ? "✗" : "–",
                    color: it.status == .done ? Theme.green : it.status == .failed ? Theme.red : .secondary,
                    detail: it.note ?? it.status.rawValue, active: it.status == .failed)
            }
        }
    }

    private func row(_ it: RetryItem, mark: String, color: Color, detail: String, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(mark).foregroundStyle(color).fixedSize()
                    .scaleEffect(mark == "⟳" ? 1.25 : 1)   // the font draws ⟳ smaller than ✓ / ✗
                Text(store.snapshot?.accountName(forProfile: it.profileId) ?? it.profileId)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(it.title).lineLimit(1).layoutPriority(1)
                Spacer(minLength: 4)
                // "in 59m" / "due" must stay whole; the account name, then the title, give way first.
                Text(detail).foregroundStyle(.secondary).lineLimit(1).layoutPriority(2)
                    .contentTransition(.numericText())
            }
            if active {
                HStack(spacing: 20) {
                    if store.isPending(Keys.queue(it.id)) {
                        LoadingLine(text: "sending…")
                    } else {
                        if it.status == .waiting || it.status == .failed {
                            Button("retry now") { Task { await store.perform(.retry(itemId: it.id)) } }
                                .buttonStyle(.clayLink)
                        }
                        Button("cancel") { Task { await store.perform(.cancelRetry(itemId: it.id)) } }
                            .buttonStyle(LinkButtonStyle(color: .secondary))
                    }
                    if it.attempts > 0 {
                        Text("\(it.attempts) attempt\(it.attempts == 1 ? "" : "s")").foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 16)
                .disabled(!store.canSend)
            }
        }
        .font(Theme.monoSmall)
        .padding(.vertical, 4)
    }

    private func when(_ it: RetryItem) -> String {
        switch it.status {
        case .verifying: return "checking reply…"
        case .waiting:
            guard let r = it.resetsAt, r > .distantPast else { return "due" }
            return r > now ? "in " + Fmt.duration(r.timeIntervalSince(now)) : "due"
        default: return it.status.rawValue
        }
    }
}

struct MovesSection: View {
    @Environment(RemoteStore.self) private var store
    let moves: [PendingMove]

    var body: some View {
        if !moves.isEmpty {
            Divider()
            SectionTitle(title: "moves", count: moves.filter { $0.status == .pending }.count) {
                if moves.contains(where: { $0.status == .pending }) {
                    if store.isPending(Keys.restart) {
                        LoadingLine(text: "restarting…")
                    } else {
                        Button("restart windows to finish") { Task { await store.perform(.restartMoves()) } }
                            .buttonStyle(.clayLink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .disabled(!store.canSend)
                    }
                }
            }
            ForEach(moves) { m in row(m) }
        }
    }

    private func row(_ m: PendingMove) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(mark(m)).foregroundStyle(color(m)).fixedSize()
                Text(m.title).lineLimit(1)
                Spacer(minLength: 4)
                Text(m.status.rawValue).foregroundStyle(color(m)).fixedSize()
            }
            Text("\(m.from.profileName) → \(m.to.label)")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, 16)
            if let note = m.note, !note.isEmpty {
                Text(note).foregroundStyle(.secondary).lineLimit(2).padding(.leading, 16)
            }
            if m.status == .done || m.status == .pending {
                HStack(spacing: 20) {
                    if store.isPending(Keys.move(m.id)) {
                        LoadingLine(text: "sending…")
                    } else if m.status == .done {
                        Button("undo") { Task { await store.perform(.undoMove(id: m.id)) } }.buttonStyle(.clayLink)
                    } else {
                        Button("cancel") { Task { await store.perform(.cancelMove(id: m.id)) } }
                            .buttonStyle(LinkButtonStyle(color: Theme.red))
                    }
                }
                .padding(.leading, 16)
                .disabled(!store.canSend)
            }
        }
        .font(Theme.monoSmall)
        .padding(.vertical, 4)
    }

    private func mark(_ m: PendingMove) -> String {
        switch m.status {
        case .pending: "→"
        case .done: "✓"
        case .failed, .conflict: "✗"
        case .undone: "↺"
        }
    }

    private func color(_ m: PendingMove) -> Color {
        switch m.status {
        case .pending: Theme.clay
        case .done: Theme.green
        case .failed, .conflict: Theme.red
        case .undone: .secondary
        }
    }
}

#Preview {
    NavigationStack { AccountsView() }
        .environment(RemoteStore(preview: Fixtures.snapshot))
        .tint(Theme.clay)
}
