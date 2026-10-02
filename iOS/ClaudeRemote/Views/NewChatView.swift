import SwiftUI
import WatchProtocol

/// Starts a chat in an account's desktop window on the Mac.
struct NewChatView: View {
    @Environment(RemoteStore.self) private var store
    @Environment(AppLock.self) private var lock
    @Environment(\.dismiss) private var dismiss

    @State private var profileId: String = ""
    @State private var cwd = ""
    @State private var prompt = ""
    @State private var folders: [FolderSuggestion] = []
    @State private var loadingFolders = false
    @FocusState private var focus: Field?

    private enum Field { case folder, prompt }

    private var accounts: [AccountStatus] { store.snapshot?.accounts ?? [] }
    private var starting: Bool { store.isPending(Keys.newChat) }
    private var canStart: Bool {
        store.canSend && !starting && !profileId.isEmpty
            && !cwd.trimmingCharacters(in: .whitespaces).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ConnectionBanner().padding(.top, 8)
                    SectionTitle("account")
                    ForEach(accounts) { a in accountRow(a) }

                    Divider().padding(.top, 8)
                    SectionTitle("folder") {
                        if loadingFolders { ProgressView().controlSize(.mini) }
                    }
                    TextField("/Users/you/Project", text: $cwd)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .folder)
                        .fieldBox(focused: focus == .folder)
                    ForEach(folders.prefix(8)) { f in
                        Button {
                            cwd = f.cwd
                        } label: {
                            HStack(spacing: 6) {
                                Text(cwd == f.cwd ? "●" : "▸").foregroundStyle(Theme.clay).fixedSize()
                                Text(Fmt.folderName(f.cwd)).lineLimit(1).layoutPriority(1)
                                // The "·" stays put: only the path itself is cut, from the front.
                                Text("·").foregroundStyle(.tertiary)
                                Text(f.cwd).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                                Spacer(minLength: 4)
                                Text(Fmt.relativeAgo(f.lastUsedAt)).foregroundStyle(.secondary).fixedSize()
                            }
                            .font(Theme.monoSmall)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 4)
                            .background(RoundedRectangle(cornerRadius: 5).fill(cwd == f.cwd ? Theme.highlight : .clear))
                            .animation(.snappy, value: cwd)
                        }
                        .buttonStyle(.row)
                        .foregroundStyle(.primary)
                    }

                    Divider().padding(.top, 8)
                    SectionTitle("prompt")
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

                    HStack {
                        Spacer()
                        if starting {
                            LoadingLine(text: "starting…").frame(minHeight: 44)
                        } else {
                            Button("↵ start") { start() }
                                .buttonStyle(.clay)
                                .disabled(!canStart)
                        }
                    }
                    .padding(.top, 14)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
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
                    Button("cancel") { dismiss() }.buttonStyle(LinkButtonStyle(color: .secondary, font: Theme.mono))
                }
            }
            .task(id: profileId) { await loadFolders() }
            .onAppear {
                if profileId.isEmpty {
                    profileId = (accounts.first { $0.state == .free } ?? accounts.first)?.id ?? ""
                }
            }
        }
        .tint(Theme.clay)
    }

    private func accountRow(_ a: AccountStatus) -> some View {
        Button {
            profileId = a.id
        } label: {
            HStack(spacing: 6) {
                Text(profileId == a.id ? "●" : "○").foregroundStyle(profileId == a.id ? Theme.clay : .secondary).fixedSize()
                Circle().fill(Theme.color(a.state)).frame(width: 7, height: 7)
                Text(a.profile.name).fontWeight(profileId == a.id ? .semibold : .regular)
                    .lineLimit(1).truncationMode(.middle).layoutPriority(1)
                Text("· 5h " + Fmt.percent(a.fiveHour.percent)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Badge(text: Theme.label(a.state), color: Theme.color(a.state))
            }
            .font(Theme.mono)
            .padding(.vertical, 7)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(profileId == a.id ? Theme.highlight : .clear))
            .animation(.snappy, value: profileId)
        }
        .buttonStyle(.row)
        .foregroundStyle(.primary)
        .accessibilityAddTraits(profileId == a.id ? .isSelected : [])
    }

    private func loadFolders() async {
        guard !profileId.isEmpty else { return }
        loadingFolders = true
        let list = await store.folders(profileId: profileId)
        loadingFolders = false
        folders = list
        if cwd.isEmpty, let first = list.first { cwd = first.cwd }
    }

    private func start() {
        let body = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = cwd.trimmingCharacters(in: .whitespaces)
        Task {
            guard await lock.confirm("Start a new chat on your Mac") else { return }
            let job = await store.perform(.newChat(profileId: profileId, cwd: folder, prompt: body))
            if job?.status == .done || job?.status == .running || job?.status == .accepted { dismiss() }
        }
    }
}

#Preview {
    NewChatView()
        .environment(RemoteStore(preview: Fixtures.snapshot))
        .environment(AppLock(previewEnabled: false))
}
