import SwiftUI
import WatchProtocol

/// What a chat is doing, like the Claude app's live view: "▸ live · 2 agents · Bash: swift test  0:42".
/// Tap to show each running command with its timer, the subagents with their current step (tap one for
/// more) and background shells.
struct LiveWorkPanel: View {
    let work: LiveWork
    @AppStorage("chat.liveExpanded") private var expanded = false
    @State private var openAgents = Set<String>()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(alignment: .leading, spacing: 5) {
                header(now: ctx.date)
                if expanded {
                    Group {
                        ForEach(work.running) { toolRow($0, now: ctx.date) }
                        ForEach(agents) { agentRow($0, now: ctx.date) }
                        ForEach(shells) { shellRow($0, now: ctx.date) }
                    }
                    .padding(.leading, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .font(Theme.monoSmall)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .padding(.bottom, expanded ? 8 : 0)
        .animation(.snappy, value: work)
    }

    /// Everything running, plus the few most recently finished, so the panel stays short.
    private var agents: [AgentRun] {
        let done = work.agents.filter { $0.status != .running }.suffix(3).map(\.id)
        return work.agents.filter { $0.status == .running || done.contains($0.id) }
    }

    private var shells: [BackgroundShell] {
        let done = work.shells.filter { $0.status != .running }.suffix(2).map(\.id)
        return work.shells.filter { $0.status == .running || done.contains($0.id) }
    }

    // MARK: Header

    private var summary: String {
        if let l = work.line { return l }
        let done = work.agents.count
        return done == 1 ? "1 agent done" : done > 0 ? "\(done) agents done" : "done"
    }

    /// The longest-running thing in flight, for the header's timer.
    private var since: Date? {
        (work.running.map(\.startedAt) + work.activeAgents.map(\.startedAt)).min()
    }

    private func header(now: Date) -> some View {
        Button {
            withAnimation(.snappy) { expanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text("▸").foregroundStyle(Theme.clay).fixedSize()
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Text("live").fontWeight(.semibold).fixedSize()
                Text(summary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let since { elapsed(now.timeIntervalSince(since)) }
                Group {
                    if work.isActive { BusyGlyph(color: Theme.yellow) } else { Text("✓").foregroundStyle(Theme.green) }
                }
                .fixedSize()
                .frame(minWidth: 14)
            }
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Live: \(summary)")
        .accessibilityHint(expanded ? "Hides what the chat is running" : "Shows what the chat is running")
    }

    // MARK: Rows

    private func toolRow(_ t: RunningTool, now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("●").foregroundStyle(Theme.yellow).fixedSize()
            Text(t.summary).lineLimit(2).truncationMode(.middle)
            Spacer(minLength: 4)
            elapsed(now.timeIntervalSince(t.startedAt))
        }
        .accessibilityElement(children: .combine)
    }

    private func agentRow(_ a: AgentRun, now: Date) -> some View {
        let open = openAgents.contains(a.id)
        return Button {
            withAnimation(.snappy) { if open { openAgents.remove(a.id) } else { openAgents.insert(a.id) } }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    status(a.status).fixedSize().frame(minWidth: 10)
                    Text(a.description)
                        .foregroundStyle(a.status == .running ? .primary : .secondary)
                        .lineLimit(open ? 3 : 1)
                    Spacer(minLength: 4)
                    if a.steps > 0 { Text("\(a.steps)").foregroundStyle(.secondary).fixedSize().contentTransition(.numericText()) }
                    elapsed((a.endedAt ?? now).timeIntervalSince(a.startedAt))
                }
                if let step = a.step, a.status == .running || open {
                    Text("└ " + step)
                        .foregroundStyle(.secondary)
                        .lineLimit(open ? 3 : 1)
                        .truncationMode(.middle)
                        .padding(.leading, 16)
                }
                if open {
                    Text(details(a))
                        .font(Theme.monoTiny)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 16)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Agent \(a.description), \(a.status.rawValue)\(a.step.map { ", " + $0 } ?? "")")
    }

    private func details(_ a: AgentRun) -> String {
        var parts = [a.type ?? "agent"]
        if a.background { parts.append("background") }
        parts.append(a.steps == 1 ? "1 tool call" : "\(a.steps) tool calls")
        parts.append("started " + Fmt.time(a.startedAt))
        if let e = a.endedAt { parts.append("ended " + Fmt.time(e)) }
        return parts.joined(separator: " · ")
    }

    private func shellRow(_ s: BackgroundShell, now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(s.kind == .monitor ? "⇢" : "$").foregroundStyle(color(s.status)).fixedSize().frame(minWidth: 10)
            Text(s.summary)
                .foregroundStyle(s.status == .running ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if s.status == .running {
                Text("bg").foregroundStyle(.tertiary).fixedSize()
                elapsed(now.timeIntervalSince(s.startedAt))
            } else {
                status(s.status).fixedSize()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(s.kind == .monitor ? "Monitor" : "Background command") \(s.summary), \(s.status.rawValue)")
    }

    // MARK: Bits

    private func elapsed(_ s: TimeInterval) -> some View {
        Text(Fmt.clock(s)).foregroundStyle(.secondary).monospacedDigit().fixedSize()
    }

    @ViewBuilder private func status(_ s: LiveWork.Status) -> some View {
        switch s {
        case .running: Text("◐").foregroundStyle(Theme.yellow)
        case .done: Text("✓").foregroundStyle(Theme.green)
        case .failed: Text("✗").foregroundStyle(Theme.red)
        case .stopped: Text("■").foregroundStyle(.secondary)
        }
    }

    private func color(_ s: LiveWork.Status) -> Color {
        switch s {
        case .running: Theme.yellow
        case .done: Theme.green
        case .failed: Theme.red
        case .stopped: .secondary
        }
    }
}

#Preview {
    VStack(spacing: 0) {
        LiveWorkPanel(work: Fixtures.work)
        Divider()
        Spacer()
    }
    .screenBackground()
}
