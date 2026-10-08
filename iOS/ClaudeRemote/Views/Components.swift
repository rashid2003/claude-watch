import SwiftUI
import WatchProtocol

// MARK: - Header

/// Inline nav bar with "✻ session-watch" as the title, and the Mac's connection dot plus a refresh glyph.
private struct RemoteHeader: ViewModifier {
    @Environment(RemoteStore.self) private var store

    func body(content: Content) -> some View {
        content
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Text("✻").foregroundStyle(Theme.clay)
                        Text("session-watch")
                        if store.isDemo {
                            Badge(text: "demo", color: Theme.clay, font: Theme.monoTiny.weight(.semibold))
                        }
                    }
                    .font(Theme.monoTitle)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(store.isDemo ? "Session Watch, demo" : "Session Watch")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.reconnect()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.clockwise").font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ConnectionDot(connection: store.connection)
                        }
                    }
                    .accessibilityLabel("Refresh, \(Theme.label(store.connection))")
                }
            }
    }
}

extension View {
    func remoteHeader() -> some View { modifier(RemoteHeader()) }
}

/// "chats · updated 12s ago" — and, when the stream isn't live, "· reconnecting  retry".
struct StatusStrip: View {
    @Environment(RemoteStore.self) private var store
    let section: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { ctx in
            HStack(spacing: 6) {
                Text(section).font(Theme.monoBold).layoutPriority(2)
                Text("·").foregroundStyle(.tertiary)
                // The age gives way first: "mac unreachable" and "retry" matter more.
                Text(updated(ctx.date)).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                if store.connection != .connected {
                    Text("·").foregroundStyle(.tertiary)
                    Text(Theme.label(store.connection)).foregroundStyle(Theme.color(store.connection))
                        .fixedSize()
                        .transition(.opacity)
                }
                Spacer(minLength: 4)
                if store.connection == .offline {
                    Button("retry") { store.reconnect() }.buttonStyle(.clayLink).fixedSize()
                }
            }
            .font(Theme.monoSmall)
            .lineLimit(1)
            .animation(.snappy, value: store.connection)
        }
        .padding(.vertical, 6)
        VersionBanner()
    }

    private func updated(_ now: Date) -> String {
        if store.isDemo { return "sample data" }
        guard let at = store.lastUpdated else { return "waiting for mac…" }
        return "updated " + Fmt.ago(at, now: now)
    }
}

/// One-line connection notice for screens without a status strip (chat, sheets).
struct ConnectionBanner: View {
    @Environment(RemoteStore.self) private var store

    var body: some View {
        if store.connection != .connected {
            TimelineView(.periodic(from: .now, by: 15)) { ctx in
                HStack(spacing: 6) {
                    ConnectionDot(connection: store.connection)
                    Text(text(ctx.date)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if store.connection == .offline {
                        Button("retry") { store.reconnect() }.buttonStyle(.clayLink).fixedSize()
                    }
                }
                .font(Theme.monoSmall)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.code))
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func text(_ now: Date) -> String {
        guard let at = store.lastUpdated else { return Theme.label(store.connection) + "…" }
        return "updated \(Fmt.ago(at, now: now)) · \(Theme.label(store.connection))"
    }
}

/// "Update Session Watch from TestFlight" / "… on the Mac" when the two speak different protocol versions.
/// Never blocks anything: what both understand keeps working.
struct VersionBanner: View {
    @Environment(RemoteStore.self) private var store

    var body: some View {
        if let hint = store.versionHint {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("↑").foregroundStyle(Theme.yellow).fixedSize()
                VStack(alignment: .leading, spacing: 2) {
                    Text(hint == .updatePhone ? "Update Session Watch from TestFlight" : "Update Session Watch on the Mac")
                        .foregroundStyle(.primary)
                    Text(hint == .updatePhone ? "Your Mac has a newer version; some features need the update."
                                              : "This iPhone has a newer version than the Mac; some features need the update.")
                        .font(Theme.monoTiny).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 4)
                Button {
                    store.dismissedHint = hint
                } label: {
                    Image(systemName: "xmark").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .font(Theme.monoSmall)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.yellow.opacity(0.12)))
            .padding(.bottom, 6)
        }
    }
}

/// Terminal-style placeholder: "○ no chats yet", with an optional hint line under it.
/// `busy` swaps the glyph for the working spinner (e.g. while waiting for the first snapshot).
struct EmptyNote: View {
    let text: String
    var hint: String?
    var glyph = "○"
    var busy = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if busy { BusyGlyph() } else { Text(glyph).foregroundStyle(.tertiary).fixedSize() }
            VStack(alignment: .leading, spacing: 3) {
                Text(text).foregroundStyle(.secondary)
                if let hint { Text(hint).font(Theme.monoTiny).foregroundStyle(.secondary) }
            }
        }
        .font(Theme.monoSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Scroll to top

/// Scrolls the modified ScrollView back to the top whenever `trigger` changes (tab bar re-tap).
private struct ScrollToTop: ViewModifier {
    let trigger: Int
    @State private var position = ScrollPosition(edge: .top)

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onChange(of: trigger) { _, _ in
                withAnimation(.snappy) { position.scrollTo(edge: .top) }
            }
    }
}

extension View {
    func scrollToTop(on trigger: Int) -> some View { modifier(ScrollToTop(trigger: trigger)) }
}

// MARK: - Toast

private struct ToastModifier: ViewModifier {
    @Environment(RemoteStore.self) private var store

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let t = store.toast {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(t.isError ? "✗" : "✓").foregroundStyle(t.isError ? Theme.red : Theme.green).fixedSize()
                    Text(t.message)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Button {
                        store.toast = nil
                    } label: {
                        Text("×").font(Theme.mono).foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle().inset(by: -6))
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, -8)   // the bigger tap area shouldn't make the toast taller
                    .accessibilityLabel("Dismiss")
                }
                .font(Theme.monoSmall)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.background))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(t.isError ? Theme.red.opacity(0.6) : Theme.green.opacity(0.6)))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: t.id) {
                    try? await Task.sleep(for: .seconds(t.isError ? 8 : 3))
                    if store.toast?.id == t.id { store.toast = nil }
                }
            }
        }
        .animation(.spring(duration: 0.3), value: store.toast)
        .sensoryFeedback(trigger: store.toast?.id) { _, _ in store.toast?.isError == true ? .error : nil }
    }
}

extension View {
    func toast() -> some View { modifier(ToastModifier()) }
}
