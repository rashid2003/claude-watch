import SwiftUI
import WatchProtocol

/// One transcript line, terminal style: "> you", plain assistant text, "● tool ✓", red errors.
struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        switch message.kind {
        case .user: user
        case .assistant: assistant
        case .tool: tool
        case .error: error
        }
    }

    private var user: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("> ").foregroundStyle(Theme.clay).fontWeight(.bold).fixedSize()
            Text(Self.markdown(message.text))
                .fontWeight(.medium)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Theme.mono)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.highlight))
        .padding(.top, 6)
    }

    private var assistant: some View {
        Text(Self.markdown(message.text))
            .font(Theme.mono)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
    }

    private var tool: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("●").foregroundStyle(dotColor).fixedSize()
            Text(message.text)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            // A text glyph (not a ProgressView) so the running state sits on the same baseline as ✓ / ✗.
            Group {
                switch message.toolOK {
                case .some(true): Text("✓").foregroundStyle(Theme.green)
                case .some(false): Text("✗").foregroundStyle(Theme.red)
                case .none: BusyGlyph(color: Theme.yellow)
                }
            }
            .fixedSize()
            .frame(minWidth: 14)
            .contentTransition(.opacity)
        }
        .animation(.snappy, value: message.toolOK)
        .font(Theme.monoSmall)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(message.text), \(message.toolOK.map { $0 ? "succeeded" : "failed" } ?? "running")")
    }

    private var dotColor: Color {
        switch message.toolOK {
        case .some(true): Theme.green
        case .some(false): Theme.red
        case .none: Theme.yellow
        }
    }

    private var error: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("✗").fixedSize()
            Text(message.text).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(Theme.monoSmall)
        .foregroundStyle(Theme.red)
        .padding(.horizontal, 8)
    }

    @MainActor private static var cache: [String: AttributedString] = [:]

    /// Inline markdown (bold, code, links) with line breaks kept; plain text if it doesn't parse.
    @MainActor static func markdown(_ text: String) -> AttributedString {
        if let hit = cache[text] { return hit }
        let parsed = (try? AttributedString(markdown: text,
                                            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        if cache.count > 500 { cache.removeAll() }
        cache[text] = parsed
        return parsed
    }
}

/// A run of tool calls as one row: "▸ 7 tools · Edited App.swift ✓". Tap to show or hide each call.
struct ToolGroupRow: View {
    let tools: [ChatMessage]
    @Binding var expanded: Bool

    private var running: ChatMessage? { tools.last { $0.toolOK == nil } }
    private var failed: Int { tools.filter { $0.toolOK == false }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(expanded ? "▾" : "▸").foregroundStyle(.secondary).fixedSize()
                    Text("\(tools.count) tools").fontWeight(.semibold).fixedSize()
                    if !expanded {
                        Text("· " + (running ?? tools[tools.count - 1]).text)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    Group {
                        if running != nil {
                            BusyGlyph(color: Theme.yellow)
                        } else if failed > 0 {
                            Text("✗ \(failed)").foregroundStyle(Theme.red)
                        } else {
                            Text("✓").foregroundStyle(Theme.green)
                        }
                    }
                    .fixedSize()
                    .frame(minWidth: 14)
                }
                .font(Theme.monoSmall)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(tools.count) tool calls\(failed > 0 ? ", \(failed) failed" : "")\(running != nil ? ", running" : "")")
            .accessibilityHint(expanded ? "Hides the tool calls" : "Shows the tool calls")
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(tools) { MessageRow(message: $0) }
                }
                .padding(.leading, 14)
                .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 2).padding(.leading, 10) }
                .transition(.opacity)
            }
        }
    }
}

/// A reply waiting on the Mac for Claude to finish its turn, or one that couldn't be sent.
struct QueuedReplyRow: View {
    let reply: QueuedReply
    let removing: Bool
    let remove: () -> Void
    var sendNow: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("> ").foregroundStyle(Theme.clay).fontWeight(.bold).fixedSize()
                Text(reply.text)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if removing {
                    ProgressView().controlSize(.small)
                } else {
                    Button(action: remove) {
                        Text("✕").foregroundStyle(.secondary).frame(minWidth: 28, minHeight: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove queued message")
                }
            }
            .font(Theme.mono)
            HStack(spacing: 8) {
                Text(reply.error.map { "not sent · " + $0 } ?? "queued · sends when Claude finishes")
                    .font(Theme.monoTiny)
                    .foregroundStyle(reply.error == nil ? Color.secondary : Theme.red)
                Spacer(minLength: 0)
                if let sendNow, !removing {
                    Button(action: sendNow) {
                        Text(reply.error == nil ? "send now ⏎" : "retry ⏎").font(Theme.monoTiny).foregroundStyle(Theme.clay)
                            .frame(minHeight: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(reply.error == nil ? "Interrupt Claude and send now" : "Retry sending")
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .padding(.top, 6)
    }
}

#Preview {
    ScrollView {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Fixtures.messages) { MessageRow(message: $0) }
        }
        .padding()
    }
    .screenBackground()
}
