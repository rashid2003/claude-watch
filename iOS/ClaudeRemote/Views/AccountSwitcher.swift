import SwiftUI
import WatchProtocol

/// Top of the Chats tab: one card per account with its state, 5h / 7d use and what needs you.
/// Tapping a card shows only that account's chats; "all" shows every account.
struct AccountSwitcher: View {
    @Environment(RemoteStore.self) private var store
    @Binding var selection: String?   // account id; nil = all accounts
    var now = Date()
    // Card sizes follow Dynamic Type so nothing is cut off at large text sizes.
    @ScaledMetric(relativeTo: .caption2) private var allWidth: CGFloat = 124
    @ScaledMetric(relativeTo: .caption2) private var cardWidth: CGFloat = 172
    @ScaledMetric(relativeTo: .caption2) private var cardHeight: CGFloat = 118
    @ScaledMetric(relativeTo: .caption2) private var percentWidth: CGFloat = 34

    var body: some View {
        if let snap = store.snapshot, snap.accounts.count > 1 {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 8) {
                        allCard(snap).id("all")
                        ForEach(snap.accounts) { a in card(a, snap).id(a.id) }
                    }
                    .fixedSize(horizontal: false, vertical: true)   // every card as tall as the tallest
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .padding(.horizontal, -16)   // bleed to the screen edges inside the padded list
                .onChange(of: selection, initial: true) { _, id in
                    withAnimation(.snappy) { proxy.scrollTo(id ?? "all", anchor: .center) }
                }
            }
            .sensoryFeedback(.selection, trigger: selection)
        }
    }

    // MARK: Cards

    private func allCard(_ snap: Snapshot) -> some View {
        let live = snap.sessions.filter { !$0.info.isArchived }
        let limited = snap.accounts.filter { $0.state == .limited }.count
        return cardShell(selected: selection == nil, width: allWidth, action: { selection = nil }) {
            HStack(spacing: 5) {
                Text("✻").foregroundStyle(Theme.clay)
                Text("all").fontWeight(.semibold)
                Spacer(minLength: 0)
                promptMark(snap.prompts.count)
            }
            .font(Theme.monoSmall)
            Text("\(snap.accounts.count) accounts").foregroundStyle(.secondary)
            if limited > 0 { Text("\(limited) limited").foregroundStyle(Theme.red).contentTransition(.numericText()) }
            Spacer(minLength: 0)
            let working = live.filter(\.isWorking).count
            if working > 0 { Text("\(working) working").foregroundStyle(Theme.yellow).contentTransition(.numericText()) }
            Text("\(live.count) chats").foregroundStyle(.secondary).contentTransition(.numericText())
        }
        .accessibilityLabel("all accounts")
        .accessibilityValue("\(snap.prompts.count) prompts, \(limited) limited")
    }

    private func card(_ a: AccountStatus, _ snap: Snapshot) -> some View {
        let chats = snap.sessions.filter { !$0.info.isArchived && (snap.account(for: $0)?.id == a.id || $0.info.profileId == a.id) }
        let prompts = snap.prompts.filter { snap.account(forProfile: $0.profileId)?.id == a.id || $0.profileId == a.id }.count
        let name = Self.split(a.profile.name)
        return cardShell(selected: selection == a.id, width: cardWidth, action: { selection = selection == a.id ? nil : a.id }) {
            HStack(spacing: 5) {
                Circle().fill(Theme.color(a.state)).frame(width: 7, height: 7)
                Text(name.title).fontWeight(.semibold).lineLimit(1).truncationMode(.middle).layoutPriority(1)
                Spacer(minLength: 0)
                promptMark(prompts)
            }
            .font(Theme.monoSmall)
            HStack(spacing: 0) {
                if let org = name.org { Text(org + " · ").foregroundStyle(.secondary) }
                Text(stateLine(a)).foregroundStyle(Theme.color(a.state)).layoutPriority(1)
            }
            .lineLimit(1)
            bar("5h", a.fiveHour.percent)
            bar("7d", a.weekly.percent)
            Spacer(minLength: 0)
            Text(counts(working: chats.filter(\.isWorking).count, total: chats.count)).foregroundStyle(.secondary)
                .lineLimit(1)
                .contentTransition(.numericText())
        }
        .accessibilityLabel(a.profile.name)
        .accessibilityValue("\(stateLine(a)), 5 hour \(Fmt.percent(a.fiveHour.percent)), \(prompts) prompts")
    }

    private func cardShell<C: View>(selected: Bool, width: CGFloat, action: @escaping () -> Void, @ViewBuilder _ content: () -> C) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button {
            withAnimation(.snappy) { action() }
        } label: {
            VStack(alignment: .leading, spacing: 4) { content() }
                .font(Theme.monoTiny)
                .padding(10)
                .frame(width: width, alignment: .topLeading)
                .frame(minHeight: cardHeight, maxHeight: .infinity, alignment: .topLeading)
                .background(shape.fill(selected ? Theme.clay.opacity(0.12) : Theme.highlight))
                .overlay(shape.strokeBorder(selected ? Theme.clay : Theme.hairline, lineWidth: selected ? 1 : 0.5))
                .contentShape(shape)
        }
        .buttonStyle(CardPress())
        .foregroundStyle(.primary)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Pieces

    @ViewBuilder private func promptMark(_ n: Int) -> some View {
        if n > 0 {
            Text("◆\(n)").font(Theme.monoTiny.weight(.bold)).foregroundStyle(Theme.clay)
                .fixedSize()
                .contentTransition(.numericText())
                .transition(.scale.combined(with: .opacity))
        }
    }

    private func bar(_ label: String, _ p: Double?) -> some View {
        HStack(spacing: 5) {
            Text(label).foregroundStyle(.secondary).fixedSize()
            UsageBar(percent: p)
            Text(Fmt.percent(p)).fixedSize().frame(minWidth: percentWidth, alignment: .trailing)
                .contentTransition(.numericText())
        }
    }

    private func counts(working: Int, total: Int) -> String {
        working > 0 ? "\(working) working · \(total) chats" : "\(total) chats"
    }

    private func stateLine(_ a: AccountStatus) -> String {
        guard a.running || [.offline, .working].contains(a.state) else { return "not running" }
        var s = Theme.label(a.state)
        if a.state == .limited, let u = a.limitedUntil { s += " · " + Fmt.time(u, now: now) }
        return s
    }

    /// "rashid@lajward.dev (Hamagan)" → "lajward.dev (Hamagan)": the user part is the same on every card.
    static func shortName(_ name: String) -> String {
        let n = split(name)
        return n.org.map { "\(n.title) (\($0))" } ?? n.title
    }

    /// "rashid@lajward.dev (Hamagan)" → ("lajward.dev", "Hamagan").
    static func split(_ name: String) -> (title: String, org: String?) {
        var title = name
        var org: String?
        if title.hasSuffix(")"), let open = title.lastIndex(of: "(") {
            org = String(title[title.index(after: open)..<title.index(before: title.endIndex)])
            title = String(title[..<open]).trimmingCharacters(in: .whitespaces)
        }
        if let at = title.firstIndex(of: "@") { title = String(title[title.index(after: at)...]) }
        return (title.isEmpty ? name : title, org)
    }
}

/// Cards sink a little while pressed.
private struct CardPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}

#Preview {
    @Previewable @State var sel: String?
    ScrollView { AccountSwitcher(selection: $sel).padding(.horizontal, 16) }
        .screenBackground()
        .environment(RemoteStore(preview: Fixtures.snapshot))
}
