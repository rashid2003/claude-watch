import SwiftUI
import UIKit
import WatchProtocol

/// One chat as a terminal transcript: live messages, its task list, any pending prompt, and a composer.
struct ChatView: View {
    @Environment(RemoteStore.self) private var store
    let chatId: String

    @State private var draft = ""
    /// Draft sync: the desktop text filled in (while untouched), when the user last edited, what the Mac last got.
    @State private var prefilled: String?
    @State private var prefilledAt: Date?
    @State private var draftAt: Date?
    @State private var postedDraft = ""
    @State private var programmatic: String?
    @State private var draftSave: Task<Void, Never>?
    @State private var tasksExpanded = false
    @State private var atBottom = true
    @State private var moveTarget: ChatLocation?
    @State private var openToolGroups = Set<String>()
    @AppStorage("chat.hideTools") private var hideTools = false
    @FocusState private var composerFocused: Bool

    private var session: SessionStatus? { store.snapshot?.session(chatId) }
    private var prompts: [PendingPrompt] { store.snapshot?.prompts(forChat: chatId) ?? [] }
    private var queued: [QueuedReply] { store.snapshot?.replies(forChat: chatId) ?? [] }

    /// A transcript line: a message, or a run of tool calls folded into one row.
    private enum Line: Identifiable {
        case message(ChatMessage)
        case tools([ChatMessage])
        var id: String {
            switch self {
            case .message(let m): m.id
            case .tools(let ms): "tools:" + ms[0].id
            }
        }
    }

    /// Two or more tool calls in a row become one collapsible group; hidden altogether with `hideTools`.
    private var lines: [Line] {
        var out: [Line] = []
        var run: [ChatMessage] = []
        func flush() {
            if run.count == 1 { out.append(.message(run[0])) } else if run.count > 1 { out.append(.tools(run)) }
            run = []
        }
        for m in store.messages {
            if m.kind == .tool {
                if !hideTools { run.append(m) }
            } else {
                flush()
                out.append(.message(m))
            }
        }
        flush()
        return out
    }

    private func toolGroupBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { openToolGroups.contains(id) },
                set: { if $0 { openToolGroups.insert(id) } else { openToolGroups.remove(id) } })
    }

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
                hideTools.toggle()
            } label: {
                Label(hideTools ? "Show tool calls" : "Hide tool calls",
                      systemImage: hideTools ? "eye" : "eye.slash")
            }
            if !openToolGroups.isEmpty {
                Button {
                    withAnimation(.snappy) { openToolGroups.removeAll() }
                } label: {
                    Label("Collapse tool calls", systemImage: "rectangle.compress.vertical")
                }
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
            if let w = liveWork {
                LiveWorkPanel(work: w)
                Divider()
            }
        }
        .background(Theme.background)
    }

    /// The open chat's live work from the Mac (the snapshot's brief copy until it arrives), while the chat
    /// works or the snapshot says something still runs. Finished items only show while it's working.
    private var liveWork: LiveWork? {
        let working = session?.isWorking == true
        guard working || session?.work != nil, let w = store.work ?? session?.work else { return nil }
        return w.isActive || (working && !w.isEmpty) ? w : nil
    }

    private func taskList(_ tasks: [TaskItem]) -> some View {
        let done = tasks.filter { $0.status == .completed }.count
        let running = tasks.filter { $0.status == .in_progress }.count
        return VStack(alignment: .leading, spacing: 3) {
            Button {
                withAnimation(.snappy) { tasksExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("▸").foregroundStyle(Theme.clay).fixedSize()
                        .rotationEffect(.degrees(tasksExpanded ? 90 : 0))
                    Text("tasks").fontWeight(.semibold).fixedSize()
                    Text("☑\(done) ◐\(running) ☐\(tasks.count - done - running)").foregroundStyle(.secondary)
                        .fixedSize()
                        .contentTransition(.numericText())
                    Spacer(minLength: 4)
                    if !tasksExpanded, let cur = session?.currentTask {
                        Text("◐ " + cur).foregroundStyle(.secondary).lineLimit(1)
                            .transition(.opacity)
                    }
                }
                .frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(tasksExpanded ? "Hides the task list" : "Shows the task list")
            if tasksExpanded {
                ForEach(tasks, id: \.id) { t in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(t.status == .completed ? "☑" : t.status == .in_progress ? "◐" : "☐")
                            .foregroundStyle(t.status == .in_progress ? Theme.yellow : t.status == .completed ? Theme.green : .secondary)
                            .fixedSize()
                        Text(t.status == .in_progress ? (t.activeForm ?? t.subject) : t.subject)
                            .foregroundStyle(t.status == .completed ? .secondary : .primary)
                            .strikethrough(t.status == .completed, color: .secondary)
                    }
                    .padding(.leading, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .font(Theme.monoSmall)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .padding(.bottom, tasksExpanded ? 8 : 0)
        .animation(.snappy, value: session?.tasks.map(\.status))
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
                        LoadingLine(text: "loading transcript…")
                            .padding(.top, 24)
                            .padding(.horizontal, 8)
                    } else if store.messages.isEmpty {
                        EmptyNote(text: "no messages yet", hint: "the transcript shows up here as the chat runs")
                            .padding(.horizontal, 8)
                    }
                    ForEach(lines) { line in
                        switch line {
                        case .message(let m): MessageRow(message: m).id(m.id)
                        case .tools(let ms): ToolGroupRow(tools: ms, expanded: toolGroupBinding(line.id)).id(line.id)
                        }
                    }
                    ForEach(queued) { r in
                        QueuedReplyRow(reply: r, removing: store.isPending(Keys.queued(r.id))) {
                            Task { await store.perform(.cancelReply(id: r.id)) }
                        }
                        .transition(.opacity)
                    }
                    if store.messagesStale && store.connection == .connected {
                        Text("refreshing…").font(Theme.monoTiny).foregroundStyle(.secondary).padding(.horizontal, 8)
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
            .onChange(of: queued.map(\.id)) { _, _ in
                if atBottom { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
        }
    }

    // MARK: Composer

    @ViewBuilder private var bottomPanel: some View {
        VStack(spacing: 8) {
            ForEach(prompts) { p in
                PromptCard(prompt: p)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                            removal: .scale(scale: 0.96, anchor: .bottom).combined(with: .opacity)))
            }
            if session?.isWorking == true {
                workingBar.transition(.opacity)
            }
            composer
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: prompts.map(\.id))
        .animation(.snappy, value: session?.isWorking)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(alignment: .top) {
            Theme.background.overlay(alignment: .top) { Divider() }.ignoresSafeArea()
        }
    }

    private var workingBar: some View {
        HStack(spacing: 8) {
            BusyGlyph(color: Theme.yellow)
            Text(session?.currentTask ?? "working…")
                .foregroundStyle(Theme.yellow)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("■ stop") {
                Haptics.deny()
                Task { await store.perform(.stop(chatId: chatId)) }
            }
            .buttonStyle(OutlineButtonStyle(color: Theme.red))
            .fixedSize()
            .disabled(!store.canSend || store.isPending(Keys.stop(chatId)))
        }
        .font(Theme.monoSmall)
    }

    private var sending: Bool { store.isPending(Keys.reply(chatId)) }
    /// Claude is mid-turn (or waiting on a prompt), so a reply is queued on the Mac.
    private var busy: Bool { session?.isWorking == true || session?.activity == .waiting || !prompts.isEmpty || queued.contains { $0.error == nil } }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if session?.canContinue == true {
                HStack(spacing: 10) {
                    Button("⟳ continue") { send("continue") }
                        .buttonStyle(.clay)
                        .fixedSize()
                        .disabled(!store.canSend || sending)
                    Text(continueNote)
                        .font(Theme.monoTiny)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity)
            }
            HStack(alignment: .bottom, spacing: 8) {
                HStack(alignment: .center, spacing: 0) {
                    Text("> ").foregroundStyle(Theme.clay).fontWeight(.bold)
                    TextField(store.canSend ? (busy ? "queue a message" : "reply") : Theme.label(store.connection) + "…",
                              text: $draft, axis: .vertical)
                        .lineLimit(1...6)
                        .focused($composerFocused)
                        .disabled(!store.canSend)
                        .submitLabel(.send)
                }
                .fieldBox(focused: composerFocused)
                if sending {
                    BusyGlyph()
                        .font(Theme.monoTitle)
                        .frame(width: 46, height: 44)
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
            if let p = prefilled, draft == p, let at = prefilledAt {
                Text("from Mac · " + Fmt.relativeAgo(at)).font(Theme.monoTiny).foregroundStyle(.secondary).transition(.opacity)
            }
            if sending {
                Text(busy ? "queueing…" : "sending…").font(Theme.monoTiny).foregroundStyle(.secondary).transition(.opacity)
            } else if busy, !draft.isEmpty {
                Text("sends when Claude finishes this turn").font(Theme.monoTiny).foregroundStyle(.secondary).transition(.opacity)
            }
        }
        .animation(.snappy, value: sending)
        .onAppear(perform: restoreDraft)
        .onDisappear { saveDraft(post: true) }
        .onChange(of: draft) { _, new in draftEdited(new) }
        .onChange(of: store.snapshot?.drafts[chatId]) { _, _ in applyRemoteDraft() }
    }

    // MARK: Draft sync

    /// Sets the composer without counting it as the user's edit.
    private func setDraft(_ text: String) {
        guard text != draft else { return }
        programmatic = text
        draft = text
    }

    private func restoreDraft() {
        if let e = LocalDrafts.load(chatId) {
            prefilled = e.prefilled
            prefilledAt = e.prefilledAt
            draftAt = e.at
            setDraft(e.text)
        }
        applyRemoteDraft()
        if !draft.isEmpty, prefilled == nil { saveDraft(post: true) }   // the Mac may not have it yet
    }

    private func draftEdited(_ new: String) {
        if programmatic == new { programmatic = nil; return }
        programmatic = nil
        prefilled = nil
        prefilledAt = nil
        draftAt = Date()
        draftSave?.cancel()
        draftSave = Task {
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { saveDraft(post: true) }
        }
    }

    /// Keeps the draft on this phone and, unless it came from the Mac, sends it there.
    private func saveDraft(post: Bool) {
        draftSave?.cancel()
        draftSave = nil
        LocalDrafts.save(chatId, .init(text: draft, at: draftAt ?? Date(), prefilled: prefilled, prefilledAt: prefilledAt))
        guard post, prefilled == nil, draft != postedDraft else { return }
        let id = chatId, text = draft
        Task { if await store.postDraft(chatId: id, text: text) { postedDraft = text } }
    }

    /// Fills an empty (or untouched) composer with a newer desktop draft; never replaces typed text.
    private func applyRemoteDraft() {
        let remote = store.snapshot?.drafts[chatId]
        guard let next = DraftMerge.composer(local: draft, prefilled: prefilled, localAt: draftAt, remote: remote) else { return }
        prefilled = next.isEmpty ? nil : next
        prefilledAt = next.isEmpty ? nil : remote?.at
        setDraft(next)
        saveDraft(post: false)
    }

    /// "stopped on a usage limit · resets 4:50pm"
    private var continueNote: String {
        let reset = session?.tail.lastRateLimit?.resetsAt.map { " · resets " + Fmt.time($0) } ?? ""
        return "stopped on a usage limit" + reset
    }

    private func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        Haptics.send()
        let before = draft
        if text == draft { draft = "" } else { postedDraft = "" }   // the Mac drops its copy on any reply
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
