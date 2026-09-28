import AppKit
import SwiftUI
import WatchCore

/// Every chat of one window/org, searchable, with a move button per row.
struct ChatsWindow: View {
    @EnvironmentObject var model: WatchModel
    @State private var locationId = ""
    @State private var query = ""
    @State private var showArchived = false
    @State private var chats: [ChatRecord] = []
    @State private var loading = false
    @State private var selection = Set<String>()

    var locations: [ChatLocation] { model.snapshot?.locations ?? [] }
    var current: ChatLocation? { locations.first { $0.id == locationId } }

    var filtered: [ChatRecord] {
        chats.filter { c in
            (showArchived || !c.isArchived)
                && (query.isEmpty || c.title.localizedCaseInsensitiveContains(query) || c.cwd.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Window", selection: $locationId) {
                    ForEach(locations) { l in Text("\(l.label) (\(l.chatCount))").tag(l.id) }
                }
                .frame(maxWidth: 380)
                TextField("Search title or folder", text: $query).textFieldStyle(.roundedBorder)
                Toggle("Archived", isOn: $showArchived)
            }
            Table(filtered, selection: $selection) {
                TableColumn("Chat") { c in
                    Text(c.title).lineLimit(1).foregroundStyle(c.isArchived ? .secondary : .primary)
                }
                TableColumn("Folder") { c in
                    Text((c.cwd as NSString).lastPathComponent).foregroundStyle(.secondary).lineLimit(1)
                }.width(170)
                TableColumn("Last active") { c in Text(Fmt.ago(c.lastActivityAt)).foregroundStyle(.secondary) }.width(90)
                TableColumn("") { c in
                    if let p = model.pendingMove(for: c.id) {
                        Text("→ " + p.to.profileName).foregroundStyle(Theme.clay).lineLimit(1)
                    } else {
                        moveMenu([c], title: "Move to")
                    }
                }.width(130)
            }
            HStack {
                Text(loading ? "Reading chats…" : "\(filtered.count) chats").foregroundStyle(.secondary)
                Spacer()
                if selection.count > 1 {
                    moveMenu(filtered.filter { selection.contains($0.id) }, title: "Move \(selection.count) chats to")
                }
            }
            RecentMoves()
        }
        .font(Theme.monoSmall)
        .padding(12)
        .frame(minWidth: 720, minHeight: 460)
        .onAppear { pickInitial() }
        .onChange(of: model.chatsProfile) { pickInitial() }
        .onChange(of: locationId) { selection = []; reload() }
        .onChange(of: model.snapshot?.moves.filter { $0.status != .pending }.count) { reload() }
    }

    func moveMenu(_ items: [ChatRecord], title: String) -> some View {
        let targets = current.map { model.destinations(from: $0) } ?? []
        return Menu(title) {
            ForEach(targets) { t in
                Button(t.label) { model.move(items.map { (id: $0.id, title: $0.title, from: $0.location) }, to: t) }
            }
        }
        .disabled(targets.isEmpty || items.contains { model.moveBlocker($0.id) != nil })
        .fixedSize()
    }

    /// Opens on the account picked in the popover: its fullest folder.
    func pickInitial() {
        let pick = model.chatsProfile.flatMap { pid in
            locations.filter { $0.profileId == pid }.max { $0.chatCount < $1.chatCount }
        } ?? locations.first
        if let pick, pick.id != locationId { locationId = pick.id } else { reload() }
    }

    func reload() {
        guard let loc = current, let p = model.profile(loc.profileId) else { chats = []; return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let list = SessionMover.listChats(at: loc, profile: p)
            DispatchQueue.main.async {
                if loc.id == locationId { chats = list }
                loading = false
            }
        }
    }
}

struct RecentMoves: View {
    @EnvironmentObject var model: WatchModel

    var body: some View {
        let recent = Array((model.snapshot?.moves ?? []).filter { $0.status != .pending }.suffix(5).reversed())
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("Recent moves").fontWeight(.semibold)
                ForEach(recent) { m in
                    HStack(spacing: 6) {
                        Text(mark(m.status).0).foregroundStyle(mark(m.status).1)
                        Text(m.title).lineLimit(1)
                        Text(m.from.profileName + " → " + m.to.profileName).foregroundStyle(.secondary).lineLimit(1)
                        if m.status != .done, let n = m.note { Text(n).foregroundStyle(.secondary).lineLimit(1) }
                        Spacer()
                        if m.status == .done, model.pendingMove(for: m.sessionId) == nil {
                            Button("Undo") { model.undoMove(m.id) }.buttonStyle(.link)
                        }
                    }
                }
            }
        }
    }

    func mark(_ s: PendingMove.Status) -> (String, Color) {
        switch s {
        case .done: ("✓", Theme.green)
        case .failed: ("✗", Theme.red)
        case .conflict: ("!", Theme.yellow)
        case .undone: ("↺", .secondary)
        case .pending: ("…", Theme.clay)
        }
    }
}
