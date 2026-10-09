import SwiftUI
import WatchProtocol

/// Starts a chat on the Mac, in an account's desktop window or as a background terminal run. The account, folder and prompt are kept as
/// a draft until the chat starts, so closing the sheet loses nothing.
struct NewChatView: View {
    @Environment(RemoteStore.self) private var store
    @Environment(AppLock.self) private var lock
    @Environment(\.dismiss) private var dismiss

    @AppStorage("newChat.profile") private var profileId = ""
    /// The last choice stays the default: "desktop" or "terminal".
    @AppStorage("newChat.target") private var targetRaw = NewChatTarget.desktop.rawValue
    @AppStorage("newChat.folder") private var cwd = ""
    @AppStorage("newChat.prompt") private var prompt = ""
    @State private var folders: [FolderSuggestion] = []
    @State private var loadingFolders = false
    @State private var showAllFolders = false
    @State private var checked: (path: String, result: FolderCheck?)?
    @State private var starting = false
    @FocusState private var focus: Field?

    private enum Field { case folder, prompt }

    /// What the Mac says about the folder in the field.
    enum FolderState: Equatable { case empty, checking, missing, untrusted, trusted, unknown }

    /// The desktop app cuts a linked prompt here.
    static let promptLimit = 14_000

    private var target: NewChatTarget { NewChatTarget(rawValue: targetRaw) ?? .desktop }
    /// Desktop chats need an account with a desktop window; a terminal run can use any account.
    private var accounts: [AccountStatus] {
        (store.snapshot?.accounts ?? []).filter { target == .terminal || !$0.profile.isTerminal }
    }
    private var folder: String { cwd.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var promptText: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var folderState: FolderState {
        guard !folder.isEmpty else { return .empty }
        if let f = folders.first(where: { $0.cwd == folder }), let t = f.trusted { return t ? .trusted : .untrusted }
        guard let checked, checked.path == folder else { return .checking }
        guard let r = checked.result else { return .unknown }
        return !r.exists ? .missing : r.trusted ? .trusted : .untrusted
    }

    private var canStart: Bool {
        store.canSend && !starting && accounts.contains { $0.id == profileId } && !promptText.isEmpty
            && promptText.count <= Self.promptLimit && [.trusted, .untrusted, .unknown].contains(folderState)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ConnectionBanner().padding(.top, 8)
                    targetSection
                    Divider().padding(.top, 8)
                    accountSection
                    Divider().padding(.top, 8)
                    folderSection
                    Divider().padding(.top, 8)
                    promptSection
                    startRow.padding(.top, 14)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .disabled(starting)
            }
            .scrollDismissesKeyboard(.interactively)
            .screenBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Text("✻").foregroundStyle(Theme.clay)
                        Text("new chat")
                    }
                    .font(Theme.monoTitle)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                        .disabled(starting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if starting {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { start() } label: { Image(systemName: "arrow.up") }
                            .accessibilityLabel(folderState == .untrusted ? "Trust and start" : "Start")
                            .disabled(!canStart)
                    }
                }
            }
            .task(id: profileId) { await loadFolders() }
            .onChange(of: targetRaw) { pickAccount() }
            .task(id: folder) { await checkFolder() }
            .onAppear(perform: pickAccount)
            .onChange(of: accounts.map(\.id)) { pickAccount() }
        }
        .tint(Theme.clay)
        .toast()
        .interactiveDismissDisabled(starting)
    }

    // MARK: Target

    @ViewBuilder private var targetSection: some View {
        SectionTitle("start in")
        Picker("Start in", selection: $targetRaw) {
            Text("Claude desktop").tag(NewChatTarget.desktop.rawValue)
            Text("Claude terminal").tag(NewChatTarget.terminal.rawValue)
        }
        .pickerStyle(.segmented)
        .padding(.vertical, 4)
        Text(target == .desktop ? "opens a chat in the account's Claude window on your mac"
                                : "runs claude in the background on your mac, no window opens")
            .font(Theme.monoSmall).foregroundStyle(.secondary).padding(.bottom, 4)
    }

    // MARK: Account

    @ViewBuilder private var accountSection: some View {
        SectionTitle("account")
        if accounts.isEmpty {
            LoadingLine(text: "waiting for your mac…").frame(minHeight: 44)
        }
        ForEach(accounts) { a in accountRow(a) }
    }

    private func accountRow(_ a: AccountStatus) -> some View {
        let on = profileId == a.id
        return Button {
            profileId = a.id
        } label: {
            HStack(spacing: 6) {
                Text(on ? "●" : "○").foregroundStyle(on ? Theme.clay : .secondary).fixedSize()
                Circle().fill(Theme.color(a.state)).frame(width: 7, height: 7)
                Text(a.profile.name).fontWeight(on ? .semibold : .regular)
                    .lineLimit(1).truncationMode(.middle).layoutPriority(1)
                Text("· 5h " + Fmt.percent(a.fiveHour.percent)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Badge(text: Theme.label(a.state), color: Theme.color(a.state))
            }
            .font(Theme.mono)
            .padding(.vertical, 7)
            .padding(.horizontal, 4)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 5).fill(on ? Theme.highlight : .clear))
            .animation(.snappy, value: profileId)
        }
        .buttonStyle(.row)
        .foregroundStyle(.primary)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: Folder

    @ViewBuilder private var folderSection: some View {
        SectionTitle("folder") {
            if loadingFolders { ProgressView().controlSize(.mini) }
        }
        HStack(spacing: 6) {
            TextField("/Users/you/Project", text: $cwd)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.next)
                .onSubmit { focus = .prompt }
                .focused($focus, equals: .folder)
            if !cwd.isEmpty && focus == .folder {
                Button { cwd = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear folder")
            }
        }
        .fieldBox(focused: focus == .folder)
        folderStatus
            .padding(.top, 6)
            .animation(.snappy, value: folderState)

        let list = shownFolders
        ForEach(list) { f in folderRow(f) }
        if folders.isEmpty && !loadingFolders {
            Text("no recent folders for this account")
                .font(Theme.monoSmall).foregroundStyle(.tertiary).padding(.vertical, 6)
        }
        if !filtering && folders.count > 6 {
            Button(showAllFolders ? "fewer" : "all \(folders.count) folders") {
                withAnimation(.snappy) { showAllFolders.toggle() }
            }
            .buttonStyle(.clayLink)
            .padding(.top, 2)
        }
    }

    @ViewBuilder private var folderStatus: some View {
        switch folderState {
        case .empty, .unknown: EmptyView()
        case .checking: LoadingLine(text: "checking the folder…")
        case .trusted: StatusLine(ok: true, text: "trusted on the mac")
        case .untrusted: StatusLine(ok: false, text: "not trusted yet · starting will trust it", warn: true)
        case .missing: StatusLine(ok: false, text: "no such folder on the mac")
        }
    }

    /// Typing something that isn't one of the suggestions narrows them down.
    private var filtering: Bool { !folder.isEmpty && !folders.contains { $0.cwd == folder } }

    private var shownFolders: [FolderSuggestion] {
        if filtering {
            return Array(folders.filter { $0.cwd.localizedCaseInsensitiveContains(folder) }.prefix(8))
        }
        return showAllFolders ? folders : Array(folders.prefix(6))
    }

    private func folderRow(_ f: FolderSuggestion) -> some View {
        let on = folder == f.cwd
        return Button {
            cwd = f.cwd
            focus = promptText.isEmpty ? .prompt : nil
        } label: {
            HStack(spacing: 6) {
                Text(on ? "●" : "▸").foregroundStyle(Theme.clay).fixedSize()
                Text(Fmt.folderName(f.cwd)).lineLimit(1).layoutPriority(1)
                // The "·" stays put: only the path itself is cut, from the front.
                Text("·").foregroundStyle(.tertiary)
                Text(f.cwd).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 4)
                if f.trusted == false { Text("untrusted").foregroundStyle(Theme.yellow).fixedSize() }
                Text(Fmt.relativeAgo(f.lastUsedAt)).foregroundStyle(.secondary).fixedSize()
            }
            .font(Theme.monoSmall)
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .frame(minHeight: 40)
            .background(RoundedRectangle(cornerRadius: 5).fill(on ? Theme.highlight : .clear))
            .animation(.snappy, value: cwd)
        }
        .buttonStyle(.row)
        .foregroundStyle(.primary)
        .accessibilityLabel("\(Fmt.folderName(f.cwd)), \(f.cwd)\(f.trusted == false ? ", untrusted" : "")")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: Prompt

    @ViewBuilder private var promptSection: some View {
        SectionTitle("prompt") {
            if promptText.count > Self.promptLimit - 2_000 {
                Text("\(promptText.count) / \(Self.promptLimit)")
                    .font(Theme.monoSmall)
                    .foregroundStyle(promptText.count > Self.promptLimit ? Theme.red : .secondary)
            }
        }
        TextEditor(text: $prompt)
            .font(Theme.mono)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 140)
            .focused($focus, equals: .prompt)
            .overlay(alignment: .topLeading) {
                if prompt.isEmpty {
                    Text("what should claude do?")
                        .font(Theme.mono)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.code))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(focus == .prompt ? Theme.clay : Theme.hairline))
    }

    private var startRow: some View {
        HStack {
            if !prompt.isEmpty && !starting {
                Button("clear draft") { prompt = "" }
                    .buttonStyle(LinkButtonStyle(color: .secondary, font: Theme.monoSmall))
            }
            Spacer()
            if starting {
                LoadingLine(text: "starting on your mac…").frame(minHeight: 44)
            } else {
                Button(folderState == .untrusted ? "↵ trust & start" : "↵ start") { start() }
                    .buttonStyle(.clay)
                    .disabled(!canStart)
            }
        }
    }

    // MARK: Actions

    private func pickAccount() {
        guard !accounts.contains(where: { $0.id == profileId }) else { return }
        profileId = (accounts.first { $0.state == .free } ?? accounts.first)?.id ?? ""
    }

    private func loadFolders() async {
        guard !profileId.isEmpty else { return }
        loadingFolders = true
        let list = await store.folders(profileId: profileId)
        loadingFolders = false
        withAnimation(.snappy) { folders = list }
        if folder.isEmpty, let first = list.first { cwd = first.cwd }
    }

    /// Asks the Mac about a typed folder once typing pauses.
    private func checkFolder() async {
        let path = folder
        guard !path.isEmpty, !folders.contains(where: { $0.cwd == path && $0.trusted != nil }) else { return }
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled else { return }
        let r = await store.checkFolder(path)
        guard !Task.isCancelled, path == folder else { return }
        checked = (path, r)
    }

    private func start() {
        guard canStart, let account = accounts.first(where: { $0.id == profileId }) else { return }
        let text = promptText, path = folder, trust = folderState == .untrusted
        let profiles = Set(account.memberProfileIds + [account.id])
        let before = Set(store.snapshot?.sessions.map(\.id) ?? [])
        focus = nil
        Task {
            let reason = trust ? "Trust \(Fmt.folderName(path)) and start a chat on your Mac" : "Start a new chat on your Mac"
            guard await lock.confirm(reason) else { return }
            starting = true
            defer { starting = false }
            guard let job = await store.perform(.newChat(profileId: account.id, cwd: path, prompt: text, trust: trust, target: target)),
                  job.status == .done else { return }   // failures show as a toast on this sheet
            Haptics.send()
            prompt = ""
            let id = await newChat(after: before, in: profiles, folder: path)
            dismiss()
            store.toast = Toast(message: job.reason ?? "Started", isError: false)
            if let id { store.deepLink = .chat(id) }
        }
    }

    /// The chat that just appeared for this account, preferring one in the chosen folder.
    private func newChat(after before: Set<String>, in profiles: Set<String>, folder: String) async -> String? {
        for _ in 0..<12 {
            let fresh = (store.snapshot?.sessions ?? []).filter { !before.contains($0.id) && profiles.contains($0.info.profileId) }
            if let s = fresh.first(where: { $0.info.cwd == folder }) ?? fresh.first { return s.id }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }
}

#Preview {
    NewChatView()
        .environment(RemoteStore(preview: Fixtures.snapshot))
        .environment(AppLock(previewEnabled: false))
}
