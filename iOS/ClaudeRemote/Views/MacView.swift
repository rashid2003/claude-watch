import SwiftUI
import UserNotifications
import WatchProtocol

/// Connection, bridge health, notification preferences, app lock and unpairing.
struct MacView: View {
    @Environment(RemoteStore.self) private var store
    @Environment(AppLock.self) private var lock
    @State private var confirmUnpair = false
    @State private var offerForce = false
    @State private var unpairing = false
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @ScaledMetric(relativeTo: .footnote) private var keyWidth: CGFloat = 72
    var scrollToTop = 0

    var body: some View {
        @Bindable var lock = lock
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                StatusStrip(section: "mac")
                Divider()
                TimelineView(.periodic(from: .now, by: 15)) { ctx in
                    VStack(alignment: .leading, spacing: 5) {
                        kv("name", store.bridgeStatus?.macName ?? store.credentials?.macName ?? "—")
                        HStack(spacing: 0) {
                            key("link")
                            ConnectionDot(connection: store.connection).padding(.trailing, 6)
                            Text(Theme.label(store.connection)).foregroundStyle(Theme.color(store.connection))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if store.connection != .connected {
                                Button("reconnect") { store.reconnect() }.buttonStyle(.clayLink).fixedSize()
                            }
                        }
                        kv("seen", store.connection == .connected ? "now" : Fmt.ago(store.lastUpdated, now: ctx.date))
                        if store.activePath == .relay {
                            kv("via", "relay · end-to-end encrypted")
                        } else if let host = store.credentials?.baseURLs.first {
                            kv("host", "\(host.host() ?? host.absoluteString):\(host.port ?? 7433)")
                        }
                        if let v = store.bridgeStatus?.version { kv("version", v) }
                    }
                    .font(Theme.monoSmall)
                    .padding(.vertical, 10)
                }

                if store.credentials?.relay != nil, !store.isDemo {
                    Divider()
                    SectionTitle("connect via")
                    connectVia
                }

                Divider()
                SectionTitle("status")
                VStack(alignment: .leading, spacing: 5) {
                    StatusLine(ok: store.isPaired, text: "paired as \(store.credentials?.deviceId ?? "—")")
                    StatusLine(ok: store.connection == .connected, text: store.connection == .connected
                               ? "bridge answering" : "bridge not answering", warn: store.connection != .offline)
                    if let s = store.bridgeStatus {
                        StatusLine(ok: s.pushConfigured, text: s.pushConfigured
                                   ? "push configured on the mac" : "push not set up · run claude-watch set-apns-key",
                                   warn: true)
                    }
                    StatusLine(ok: notificationStatus == .authorized || notificationStatus == .provisional,
                               text: notificationStatus == .denied ? "notifications off in settings"
                                   : notificationStatus == .notDetermined ? "notifications not asked yet" : "notifications allowed",
                               warn: notificationStatus != .denied)
                    ForEach(store.bridgeStatus?.warnings ?? [], id: \.self) { w in
                        StatusLine(ok: false, text: w)
                    }
                }
                .padding(.bottom, 10)

                Divider()
                SectionTitle("notify")
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(NotifyEvent.allCases, id: \.self) { e in
                        Toggle(isOn: notifyBinding(e)) {
                            HStack(spacing: 6) {
                                Text("▸").foregroundStyle(Theme.clay).fixedSize()
                                Text(title(e))
                            }
                        }
                        .frame(minHeight: 40)
                        .disabled(!store.canSend)
                    }
                }
                .font(Theme.monoSmall)
                .tint(Theme.clay)
                .padding(.bottom, 10)

                Divider()
                SectionTitle("security")
                Toggle(isOn: $lock.enabled) {
                    HStack(spacing: 6) {
                        Text("▸").foregroundStyle(Theme.clay).fixedSize()
                        Text("require face id")
                    }
                }
                .frame(minHeight: 40)
                .font(Theme.monoSmall)
                .tint(Theme.clay)
                Text("asked on open, before allowing a shell command, and before a new chat")
                    .font(Theme.monoTiny)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 14)
                    .padding(.bottom, 10)

                Divider()
                if store.isDemo {
                    demoRow
                } else {
                    HStack(spacing: 10) {
                        Button { confirmUnpair = true } label: {
                            Text("unpair this iphone").frame(minHeight: 36)
                        }
                        .buttonStyle(LinkButtonStyle(color: Theme.red, font: Theme.mono))
                        .disabled(unpairing)
                        if unpairing { BusyGlyph(color: Theme.red).font(Theme.mono) }
                    }
                    .padding(.vertical, 6)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollToTop(on: scrollToTop)
        .dockClearance()
        .screenBackground()
        .navigationTitle("mac")
        .remoteHeader()
        .refreshable { await store.refreshStatus() }
        .task {
            await store.refreshStatus()
            notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        }
        .confirmationDialog("Unpair from \(store.credentials?.macName ?? "your Mac")?", isPresented: $confirmUnpair,
                            titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { unpair(force: false) }
        } message: {
            Text("You'll need to scan a new pairing code to connect again.")
        }
        .alert("Couldn't reach your Mac", isPresented: $offerForce) {
            Button("Forget anyway", role: .destructive) { unpair(force: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Forget the pairing on this iPhone only? Revoke it on the Mac as well from Pair iPhone….")
        }
    }

    /// In the in-app demo: what it is, and the way back to pairing.
    private var demoRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Badge(text: "demo", color: Theme.clay)
                Text("sample data · nothing reaches a mac").font(Theme.monoSmall).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Button {
                withAnimation(.easeInOut(duration: 0.3)) { store.exitDemo() }
            } label: {
                Text("› exit demo").frame(minHeight: 36)
            }
            .buttonStyle(LinkButtonStyle(color: Theme.clay, font: Theme.mono))
            .accessibilityHint("Goes back to the pairing screen")
        }
        .padding(.vertical, 10)
    }

    /// auto / direct / relay, as a radio list.
    private var connectVia: some View {
        let current = store.credentials?.via ?? .auto
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(ConnectVia.allCases, id: \.self) { v in
                Button {
                    guard v != current else { return }
                    Task { await store.setConnectVia(v) }
                } label: {
                    HStack(spacing: 8) {
                        Text(v == current ? "◉" : "○").foregroundStyle(v == current ? Theme.clay : .secondary).fixedSize()
                        Text(v.rawValue).fontWeight(v == current ? .semibold : .regular)
                        Text(Self.viaNote(v)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(v == current ? .isSelected : [])
            }
        }
        .font(Theme.monoSmall)
        .padding(.bottom, 10)
        .sensoryFeedback(.selection, trigger: current)
    }

    private static func viaNote(_ v: ConnectVia) -> String {
        switch v {
        case .auto: "tailscale first, else relay"
        case .direct: "tailscale / same network"
        case .relay: "anywhere, encrypted"
        }
    }

    private func key(_ k: String) -> some View {
        Text(k).foregroundStyle(.secondary).lineLimit(1).fixedSize().frame(minWidth: keyWidth, alignment: .leading)
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack(spacing: 0) {
            key(k)
            Text(v).lineLimit(1).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func notifyBinding(_ e: NotifyEvent) -> Binding<Bool> {
        Binding(get: { store.bridgeStatus?.notify[e.rawValue] ?? true },
                set: { on in Task { await store.setNotify(e, on: on) } })
    }

    private func title(_ e: NotifyEvent) -> String {
        switch e {
        case .prompt: "permission prompts"
        case .finished: "chat finished"
        case .failed: "chat failed / hit limit"
        case .account: "limit reset · cap soon"
        }
    }

    private func unpair(force: Bool) {
        unpairing = true
        Task {
            let ok = await store.unpair(force: force)
            unpairing = false
            if !ok { store.toast = nil; offerForce = true }
        }
    }
}

#Preview {
    NavigationStack { MacView() }
        .environment(RemoteStore(preview: Fixtures.snapshot))
        .environment(AppLock(previewEnabled: true))
        .tint(Theme.clay)
}
