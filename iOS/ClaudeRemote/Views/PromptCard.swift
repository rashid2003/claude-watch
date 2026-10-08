import SwiftUI
import WatchProtocol

/// A pending permission prompt (allow / always / deny), or a question that has to be answered on the Mac.
/// A terminal chat's prompt without the prompt hook is view-only: it's answered in the terminal.
struct PromptCard: View {
    @Environment(RemoteStore.self) private var store
    @Environment(AppLock.self) private var lock
    let prompt: PendingPrompt
    @State private var showDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("◆").foregroundStyle(Theme.clay).fixedSize()
                Text(prompt.kind == .permission ? "needs you" : "question").fontWeight(.semibold).fixedSize()
                Text("· " + prompt.toolName).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    Text(Fmt.relativeAgo(prompt.at, now: ctx.date)).font(Theme.monoTiny).foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            .font(Theme.monoSmall)

            if prompt.kind == .permission {
                code(prompt.summary, lines: showDetail ? nil : 3)
                if let detail = prompt.detail, !detail.isEmpty, detail != prompt.summary {
                    Button {
                        withAnimation(.snappy) { showDetail.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Text("▸").rotationEffect(.degrees(showDetail ? 90 : 0)).fixedSize()
                            Text("detail")
                        }
                    }
                    .buttonStyle(LinkButtonStyle(color: .secondary))
                    if showDetail {
                        ScrollView { code(detail, lines: nil) }
                            .frame(maxHeight: 180)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                if prompt.viewOnly == true {
                    Text("Answer this in the terminal on the Mac").font(Theme.monoSmall).foregroundStyle(.secondary)
                } else {
                    buttons
                }
            } else {
                Text(prompt.summary).font(Theme.mono)
                Text("answer on mac").font(Theme.monoSmall).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.background))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.clay, lineWidth: 1))
        .animation(.snappy, value: sending)
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
            LoadingLine(text: "sending…")
                .frame(minHeight: 44)
                .transition(.opacity)
        } else {
            HStack(spacing: 8) {
                Button("allow") { answer(.allow) }.buttonStyle(.clay).fixedSize()
                if prompt.canAllowAlways {
                    Button("always") { answer(.allowAlways) }.buttonStyle(.outline).fixedSize()
                }
                Spacer(minLength: 8)
                Button { answer(.deny) } label: {
                    Text("deny").frame(minWidth: 56, minHeight: 36, alignment: .trailing)
                }
                .buttonStyle(LinkButtonStyle(color: Theme.red, font: Theme.mono))
                .fixedSize()
                .padding(.trailing, 4)
            }
            .disabled(!store.canSend)
            .transition(.opacity)
        }
    }

    private func answer(_ d: PromptDecision) {
        Task {
            // Allowing a shell command is the riskiest thing the phone can do: ask for Face ID again.
            if d != .deny, prompt.toolName == "Bash",
               !(await lock.confirm("Allow “\(prompt.summary.prefix(60))”")) { return }
            if d == .deny { Haptics.deny() } else { Haptics.allow() }
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
