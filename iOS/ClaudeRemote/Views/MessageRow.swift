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
            Text("> ").foregroundStyle(Theme.clay).fontWeight(.bold)
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
            Text("●").foregroundStyle(dotColor)
            Text(message.text)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            switch message.toolOK {
            case .some(true): Text("✓").foregroundStyle(Theme.green)
            case .some(false): Text("✗").foregroundStyle(Theme.red)
            case .none: ProgressView().controlSize(.mini)
            }
        }
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
            Text("✗")
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

#Preview {
    ScrollView {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Fixtures.messages) { MessageRow(message: $0) }
        }
        .padding()
    }
    .screenBackground()
}
