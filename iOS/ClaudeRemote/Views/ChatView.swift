import SwiftUI
import UIKit
import WatchProtocol

/// One chat as a terminal transcript: live messages, its task list, any pending prompt, and a composer.
struct ChatView: View {
    @Environment(RemoteStore.self) private var store
    let chatId: String

    @State private var draft = ""
    @State private var tasksExpanded = false
    @State private var atBottom = true
    @State private var moveTarget: ChatLocation?
    @FocusState private var composerFocused: Bool

    private var session: SessionStatus? { store.snapshot?.session(chatId) }
    private var prompts: [PendingPrompt] { store.snapshot?.prompts(forChat: chatId) ?? [] }

    var body: some View {
        messageList
            .screenBackground()
            .safeAreaInset(edge: .top, spacing: 0) { topPanel }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomPanel }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .toolbar {
                ToolbarItem(placement: .principal) { titleView }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if session?.isWorking == true { stopButton }
                    menu
                }
            }
            .onAppear { store.open(chat: chatId) }
            .onDisappear { store.close(chat: chatId) }
            .confirmationDialog(moveTarget.map { "Move to \($0.label)?" } ?? "", isPresented: moveBinding,
                                titleVisibility: .visible, presenting: moveTarget) { loc in
                Button("Move") { Task { await store.perform(.move(sessionId: chatId, toLocationId: loc.id)) } }
            } message: { _ in
                Text("The chat is moved when the desktop windows restart. You can undo it from Accounts → moves.")
            }
    }

    // MARK: Header

    private var titleView: some View {
        VStack(spacing: 1) {
            Text(session?.info.title ?? "chat")
                .font(Theme.monoBold)
                .lineLimit(1)
            if let s = session {
                HStack(spacing: 4) {
                    Circle().fill(activityColor(s)).frame(width: 6, height: 6)
                    Text("\(store.snapshot?.accountName(forProfile: s.info.profileId) ?? s.info.profileId) · \(Fmt.folderName(s.info.cwd))")
                }
                .font(Theme.monoTiny)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func activityColor(_ s: SessionStatus) -> Color {
        if !prompts.isEmpty || s.activity == .waiting { return Theme.clay }
        switch s.activity {
        case .working: return Theme.yellow
        case .failed: return Theme.red
        default: return s.isRateLimited ? Theme.red : .secondary
        }
    }

    private var stopButton: some View {
        Button {
            Task { await store.perform(.stop(chatId: chatId)) }
        } label: {
            if store.isPending(Keys.stop(chatId)) {
                ProgressView()
            } else {
                Text("■").font(Theme.mono).foregroundStyle(Theme.red)
            }
        }
        .disabled(!store.canSend || store.isPending(Keys.stop(chatId)))
        .accessibilityLabel("Stop")
    }

    private var menu: some View {
        Menu {
            if let s = session, let snap = store.snapshot {
                let destinations = snap.moveDestinations(for: s)
                Menu {
                    ForEach(destinations) { loc in
                        Button("\(loc.label) (\(loc.chatCount))") { moveTarget = loc }
                    }
                } label: {
                    Label("Move to account…", systemImage: "arrow.left.arrow.right")
                }
                .disabled(destinations.isEmpty || !store.canSend || store.isPending(Keys.moveChat(chatId)))
            }
            Button {
                UIPasteboard.general.string = session?.info.cliSessionId ?? chatId
            } label: {
                Label("Copy session id", systemImage: "doc.on.doc")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("More")
    }

    private var moveBinding: Binding<Bool> {
        Binding(get: { moveTarget != nil }, set: { if !$0 { moveTarget = nil } })
    }

    @ViewBuilder private var topPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.connection != .connected {
                ConnectionBanner().padding(.horizontal, 12).padding(.vertical, 6)
            }
            if let tasks = session?.tasks, !tasks.isEmpty {
                taskList(tasks)
                Divider()
            }
        }
        .background(Theme.background)
    }

    private func taskList(_ tasks: [TaskItem]) -> some View {
        let done = tasks.filter { $0.status == .completed }.count
        let running = tasks.filter { $0.status == .in_progress }.count
        return VStack(alignment: .leading, spacing: 3) {
            Button {
                withAnimation(.snappy) { tasksExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(tasksExpanded ? "▾" : "▸").foregroundStyle(Theme.clay)
                    Text("tasks").fontWeight(.semibold)
                    Text("☑\(done) ◐\(running) ☐\(tasks.count - done - running)").foregroundStyle(.secondary)
                    Spacer()
                    if !tasksExpanded, let cur = session?.currentTask {
                        Text("◐ " + cur).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if tasksExpanded {
                ForEach(tasks, id: \.id) { t in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(t.status == .completed ? "☑" : t.status == .in_progress ? "◐" : "☐")
                            .foregroundStyle(t.status == .in_progress ? Theme.yellow : t.status == .completed ? Theme.green : .secondary)
                        Text(t.status == .in_progress ? (t.activeForm ?? t.subject) : t.subject)
                            .foregroundStyle(t.status == .completed ? .secondary : .primary)
                            .strikethrough(t.status == .completed, color: .secondary)
                    }
                    .padding(.leading, 14)
                }
            }
        }
        .font(Theme.monoSmall)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if store.olderCursor != nil {
                        HStack {
                            Spacer()
                            if store.loadingOlder {
                                ProgressView().controlSize(.small)
                            } else {
                                Button("↑ load earlier") { Task { await store.loadOlder() } }
                                    .buttonStyle(.clayLink)
                            }
                            Spacer()
                        }
                        .onAppear { Task { await store.loadOlder() } }
                    }
                    if !store.messagesLoaded {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("loading transcript…")
                        }
                        .font(Theme.monoSmall)
                        .foregroundStyle(.secondary)
                        .padding(.top, 24)
                        .padding(.horizontal, 8)
                    } else if store.messages.isEmpty {
                        EmptyNote(text: "no messages yet").padding(.horizontal, 8)
                    }
                    ForEach(store.messages) { m in
                        MessageRow(message: m).id(m.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 80
            } action: { _, bottom in
                atBottom = bottom
            }
            .onChange(of: store.messages.last?.id) { _, _ in
                if atBottom { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
        }
    }

    // MARK: Composer

    @ViewBuilder private var bottomPanel: some View {
        VStack(spacing: 8) {
            ForEach(prompts) { PromptCard(prompt: $0) }
            if session?.isWorking == true {
                workingBar
            } else {
                composer
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(alignment: .top) {
            Theme.background.overlay(alignment: .top) { Divider() }.ignoresSafeArea()
        }
    }

    private var workingBar: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(session?.currentTask ?? "working…")
                .foregroundStyle(Theme.yellow)
                .lineLimit(1)
            Spacer()
            Button("■ stop") { Task { await store.perform(.stop(chatId: chatId)) } }
                .buttonStyle(OutlineButtonStyle(color: Theme.red))
                .disabled(!store.canSend || store.isPending(Keys.stop(chatId)))
        }
        .font(Theme.monoSmall)
        .padding(.vertical, 4)
    }

    private var sending: Bool { store.isPending(Keys.reply(chatId)) }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if session?.canContinue == true {
                HStack {
                    Button("⟳ continue") { send("continue") }
                        .buttonStyle(.clay)
                        .disabled(!store.canSend || sending)
                    Text("the chat stopped on a usage limit")
                        .font(Theme.monoTiny)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                HStack(alignment: .center, spacing: 0) {
                    Text("> ").foregroundStyle(Theme.clay).fontWeight(.bold)
                    TextField(store.canSend ? "reply" : "mac offline", text: $draft, axis: .vertical)
                        .lineLimit(1...6)
                        .focused($composerFocused)
                        .disabled(!store.canSend)
                        .submitLabel(.send)
                }
                .fieldBox(focused: composerFocused)
                if sending {
                    ProgressView()
                        .frame(width: 40, height: 38)
                        .accessibilityLabel("Sending")
                } else {
                    Button {
                        send(draft)
                    } label: {
                        Text("↵").font(Theme.monoTitle).frame(width: 18)
                    }
                    .buttonStyle(.clay)
                    .disabled(!store.canSend || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send")
                }
            }
            if sending {
                Text("sending…").font(Theme.monoTiny).foregroundStyle(.secondary)
            }
        }
    }

    private func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let before = draft
        if text == draft { draft = "" }
        Task {
            let job = await store.perform(.reply(chatId: chatId, text: t))
            // Put the text back if the Mac never took it, so nothing typed is lost.
            if job == nil || job?.status == .failed || job?.status == .blocked, draft.isEmpty, text == before {
                draft = before
            }
        }
    }
}

#Preview {
    NavigationStack { ChatView(chatId: "local_a2") }
        .environment(RemoteStore(preview: Fixtures.snapshot, messages: Fixtures.messages))
        .environment(AppLock(previewEnabled: false))
        .tint(Theme.clay)
}
