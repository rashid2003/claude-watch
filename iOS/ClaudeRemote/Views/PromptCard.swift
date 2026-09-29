import SwiftUI
import WatchProtocol

/// A pending permission prompt (allow / always / deny), or a question that has to be answered on the Mac.
struct PromptCard: View {
    @Environment(RemoteStore.self) private var store
    @Environment(AppLock.self) private var lock
    let prompt: PendingPrompt
    @State private var showDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("◆").foregroundStyle(Theme.clay)
                Text(prompt.kind == .permission ? "needs you" : "question").fontWeight(.semibold)
                Text("· " + prompt.toolName).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text(Fmt.relativeAgo(prompt.at)).font(Theme.monoTiny).foregroundStyle(.secondary)
            }
            .font(Theme.monoSmall)

            if prompt.kind == .permission {
                code(prompt.summary, lines: showDetail ? nil : 3)
                if let detail = prompt.detail, !detail.isEmpty, detail != prompt.summary {
                    Button {
                        withAnimation(.snappy) { showDetail.toggle() }
                    } label: {
                        Text((showDetail ? "▾" : "▸") + " detail")
                    }
                    .buttonStyle(LinkButtonStyle(color: .secondary))
                    if showDetail {
                        ScrollView { code(detail, lines: nil) }
                            .frame(maxHeight: 180)
                    }
                }
                buttons
            } else {
                Text(prompt.summary).font(Theme.mono)
                Text("answer on mac").font(Theme.monoSmall).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.background))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.clay, lineWidth: 1))
    }

    private func code(_ text: String, lines: Int?) -> some View {
        Text(text)
            .font(Theme.monoSmall)
            .lineLimit(lines)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.code))
    }

    private var sending: Bool { store.isPending(Keys.prompt(prompt.id)) }

    @ViewBuilder private var buttons: some View {
        if sending {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("sending…").foregroundStyle(.secondary)
            }
            .font(Theme.monoSmall)
            .padding(.vertical, 6)
        } else {
            HStack(spacing: 8) {
                Button("allow") { answer(.allow) }.buttonStyle(.clay)
                if prompt.canAllowAlways {
                    Button("always") { answer(.allowAlways) }.buttonStyle(.outline)
                }
                Spacer()
                Button("deny") { answer(.deny) }
                    .buttonStyle(LinkButtonStyle(color: Theme.red, font: Theme.mono))
                    .padding(.trailing, 4)
            }
            .disabled(!store.canSend)
        }
    }

    private func answer(_ d: PromptDecision) {
        Task {
            // Allowing a shell command is the riskiest thing the phone can do: ask for Face ID again.
            if d != .deny, prompt.toolName == "Bash",
               !(await lock.confirm("Allow “\(prompt.summary.prefix(60))”")) { return }
            await store.perform(.answer(chatId: prompt.chatId, promptId: prompt.id, decision: d))
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        ForEach(Fixtures.snapshot.prompts) { PromptCard(prompt: $0) }
        PromptCard(prompt: PendingPrompt(id: "q", chatId: "c", profileId: "default", chatTitle: "Plan",
                                         toolName: "AskUserQuestion", summary: "Which database should I use?",
                                         source: .desktop, kind: .question, at: .now))
    }
    .padding()
    .screenBackground()
    .environment(RemoteStore(preview: Fixtures.snapshot))
    .environment(AppLock(previewEnabled: false))
}
