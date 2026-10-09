import SwiftUI
import UIKit
import WatchProtocol

/// The buddy at the top of the chats list: its mood follows the chats, a tap opens the one that needs you.
struct BuddyBanner: View {
    @Environment(RemoteStore.self) private var store
    @AppStorage("buddy.show") private var show = true
    @AppStorage("buddy.style") private var styleRaw = BuddyStyle.blobby.rawValue
    @AppStorage("buddy.haptics") private var haptics = true
    @State private var tracker = BuddyTracker()
    @State private var state = BuddyState.asleep

    private var style: BuddyStyle { BuddyStyle(rawValue: styleRaw) ?? .blobby }

    var body: some View {
        if show {
            Button(action: open) {
                HStack(spacing: 10) {
                    TimelineView(.animation) { tl in
                        BuddyView(style: style, mood: state.mood, t: tl.date.timeIntervalSinceReferenceDate)
                            .frame(width: 84, height: 84)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(headline).font(Theme.monoBold).foregroundStyle(BuddyPalette.accent(state.mood))
                        Text(detail).font(Theme.monoSmall).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .animation(.snappy, value: state.mood)
            .onChange(of: store.snapshot?.at, initial: true) { _, _ in refresh() }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(headline). \(detail)")
            Divider()
        }
    }

    private var headline: String {
        switch state.mood {
        case .needsYou: state.needsYou.count > 1 ? "\(state.needsYou.count) chats need you!" : "a chat needs you!"
        case .error: "something broke"
        case .celebrating: "all done!"
        case .busy: state.working.count > 1 ? "\(state.working.count) chats working" : "working on it"
        case .sleeping: "all quiet"
        }
    }

    private var detail: String {
        switch state.mood {
        case .needsYou, .error, .celebrating: state.urgent.map { "\($0.title) · \($0.reason)" } ?? ""
        case .busy: state.working.first?.title ?? ""
        case .sleeping: "nothing running. tap to see your chats"
        }
    }

    private func refresh() {
        let before = state.mood
        state = tracker.update(store.snapshot)
        if haptics, state.mood == .needsYou, before != .needsYou { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
        if haptics, state.mood == .celebrating, before != .celebrating { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    }

    private func open() {
        if state.mood != .sleeping, let c = state.urgent { store.deepLink = .chat(c.id) }
    }
}

/// "buddy" section of the Mac tab: on/off, character, haptics.
struct BuddySettingsRows: View {
    @AppStorage("buddy.show") private var show = true
    @AppStorage("buddy.style") private var styleRaw = BuddyStyle.blobby.rawValue
    @AppStorage("buddy.haptics") private var haptics = true

    var body: some View {
        SectionTitle("buddy")
        Toggle(isOn: $show) { row("show it on the chats tab") }
        Toggle(isOn: $haptics) { row("buzz when a chat needs you") }
        HStack(spacing: 8) {
            ForEach(BuddyStyle.allCases) { s in
                Button { styleRaw = s.rawValue } label: {
                    VStack(spacing: 2) {
                        TimelineView(.animation) { tl in
                            BuddyView(style: s, mood: .busy, t: tl.date.timeIntervalSinceReferenceDate).frame(width: 64, height: 64)
                        }
                        Text(s.title.lowercased()).font(Theme.monoTiny)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 10).fill(styleRaw == s.rawValue ? Theme.clay.opacity(0.18) : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(styleRaw == s.rawValue ? Theme.clay : Theme.hairline))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 10)
    }

    private func row(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text("▸").foregroundStyle(Theme.clay).fixedSize()
            Text(text)
        }
        .font(Theme.monoSmall)
        .frame(minHeight: 40)
    }
}
