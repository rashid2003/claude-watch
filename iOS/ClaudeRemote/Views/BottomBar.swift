import SwiftUI
import WatchProtocol

enum AppTab: Hashable, CaseIterable {
    case chats, accounts, mac

    var title: String {
        switch self {
        case .chats: "chats"
        case .accounts: "accounts"
        case .mac: "mac"
        }
    }

    var symbol: String {
        switch self {
        case .chats: "text.bubble"
        case .accounts: "gauge.with.dots.needle.50percent"
        case .mac: "desktopcomputer"
        }
    }
}

/// Floating dock: a capsule with chats · accounts · mac (live status on each), and a clay "new chat" key beside it.
struct BottomBar: View {
    @Environment(RemoteStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: AppTab
    /// Accounts that came back from a limit since the Accounts tab was last looked at.
    let recoveredAccounts: Set<String>
    let onReselect: (AppTab) -> Void
    let onNewChat: () -> Void
    @Namespace private var indicator

    private static let height: CGFloat = 54
    private static let radius: CGFloat = 16

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(AppTab.allCases, id: \.self) { item($0) }
            }
            .padding(4)
            .frame(height: Self.height)
            .background(dock)
            newChatButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background {
            // Fades the list out under the dock instead of cutting it off.
            LinearGradient(colors: [Theme.background.opacity(0), Theme.background.opacity(0.92)],
                           startPoint: .top, endPoint: .init(x: 0.5, y: 0.55))
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
        }
        .sensoryFeedback(.selection, trigger: selection)
    }

    private var dock: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        return shape.fill(.ultraThinMaterial)
            .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.22), radius: 14, y: 5)
    }

    // MARK: Items

    private func item(_ tab: AppTab) -> some View {
        let selected = selection == tab
        return Button {
            if selected {
                onReselect(tab)
            } else {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) { selection = tab }
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 16, weight: selected ? .semibold : .regular))
                    .frame(height: 20)
                    .overlay(alignment: .topTrailing) {
                        status(tab)
                            .alignmentGuide(.trailing) { $0[.leading] + 9 }
                            .alignmentGuide(.top) { $0.height / 2 + 1 }
                    }
                Text(tab.title)
                    .font(Theme.monoTiny)
                    .fontWeight(selected ? .semibold : .regular)
            }
            .foregroundStyle(selected ? Theme.clay : .secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: Self.radius - 4, style: .continuous)
                        .fill(Theme.clay.opacity(0.14))
                        .overlay(RoundedRectangle(cornerRadius: Self.radius - 4, style: .continuous)
                            .strokeBorder(Theme.clay.opacity(0.25), lineWidth: 0.5))
                        .matchedGeometryEffect(id: "indicator", in: indicator)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityValue(accessibilityValue(tab))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityHint(selected ? "Double-tap to go back to the top" : "")
    }

    @ViewBuilder private func status(_ tab: AppTab) -> some View {
        switch tab {
        case .chats:
            if promptCount > 0 {
                pill("◆\(promptCount)", Theme.clay)
                    .phaseAnimator(reduceMotion ? [1.0] : [1.0, 0.55]) { v, o in v.opacity(o) } animation: { _ in
                        .easeInOut(duration: 0.9)
                    }
            } else if workingCount > 0 {
                pill("\(workingCount)", Theme.yellow)
            }
        case .accounts:
            if anyLimited {
                dot(Theme.red)
            } else if !recoveredAccounts.isEmpty {
                dot(Theme.green)
            }
        case .mac:
            dot(Theme.color(store.connection))
        }
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            .foregroundStyle(.black.opacity(0.85))
            .padding(.horizontal, 4)
            .frame(minWidth: 15, minHeight: 15)
            .background(Capsule().fill(color))
            .overlay(Capsule().stroke(Theme.background, lineWidth: 1.5))
            .fixedSize()
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .overlay(Circle().stroke(Theme.background, lineWidth: 1.5))
    }

    private var canCreate: Bool { store.canSend && store.snapshot != nil }

    private var newChatButton: some View {
        Button(action: onNewChat) {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.black.opacity(0.85))
                .frame(width: Self.height, height: Self.height)
                .background(RoundedRectangle(cornerRadius: Self.radius, style: .continuous).fill(Theme.clay))
                .shadow(color: Theme.clay.opacity(canCreate ? 0.4 : 0), radius: 12, y: 4)
        }
        .buttonStyle(PressScale())
        .disabled(!canCreate)
        .opacity(canCreate ? 1 : 0.4)
        .accessibilityLabel("New chat")
    }

    // MARK: Status

    private var promptCount: Int { store.prompts.count }
    private var workingCount: Int { store.snapshot?.sessions.filter(\.isWorking).count ?? 0 }
    private var anyLimited: Bool { store.snapshot?.accounts.contains { $0.state == .limited } ?? false }

    private func accessibilityValue(_ tab: AppTab) -> String {
        switch tab {
        case .chats:
            if promptCount > 0 { return "\(promptCount) prompt\(promptCount == 1 ? "" : "s") waiting" }
            return workingCount > 0 ? "\(workingCount) working" : ""
        case .accounts:
            if anyLimited { return "an account is limited" }
            return recoveredAccounts.isEmpty ? "" : "an account is free again"
        case .mac:
            return Theme.label(store.connection)
        }
    }
}

private struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

#Preview {
    @Previewable @State var tab = AppTab.chats
    VStack {
        Spacer()
        BottomBar(selection: $tab, recoveredAccounts: [], onReselect: { _ in }, onNewChat: {})
    }
    .screenBackground()
    .environment(RemoteStore(preview: Fixtures.snapshot))
}
