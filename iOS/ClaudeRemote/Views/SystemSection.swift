import SwiftUI
import WatchProtocol

/// The Mac's memory, swap, CPU and disk with their trend, the heaviest apps, and what to do about them.
/// Streams while visible (`watchSystem`).
struct SystemSection: View {
    @Environment(RemoteStore.self) private var store
    @State private var confirm: Pending?
    @State private var showClean = false
    @State private var autoPending: Bool?
    @ScaledMetric(relativeTo: .footnote) private var keyWidth: CGFloat = 60

    enum Pending: Identifiable {
        case quit(AppUsage), kill(AppUsage), closeIdle
        var id: String {
            switch self {
            case .quit(let a): "quit:" + a.id
            case .kill(let a): "kill:" + a.id
            case .closeIdle: "idle"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle("system") {
                if let h = store.system {
                    HStack(spacing: 5) {
                        Circle().fill(color(h.level)).frame(width: 7, height: 7)
                        Text(label(h.level)).foregroundStyle(color(h.level))
                    }
                    .font(Theme.monoSmall)
                }
            }
            if let h = store.system {
                content(h)
            } else {
                Text(store.connection == .connected ? "reading the mac…" : "mac not connected")
                    .font(Theme.monoSmall).foregroundStyle(.secondary).padding(.bottom, 10)
            }
        }
        .onAppear { store.watchSystem() }
        .onDisappear { store.unwatchSystem() }
        .onChange(of: store.system?.auto.enabled) { _, _ in autoPending = nil }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible, presenting: confirm) { p in
            switch p {
            case .quit(let a): Button("Quit \(a.name)") { send(.quitApp(a)) }
            case .kill(let a): Button("Kill \(a.name)", role: .destructive) { send(.kill(a)) }
            case .closeIdle: Button("Close idle windows") { send(.closeIdleClaude()) }
            }
        } message: { p in
            switch p {
            case .quit: Text("Asks the app to quit, like ⌘Q. It may ask to save first.")
            case .kill(let a): Text("Kills pid \(a.mainPid) immediately. Unsaved work in it is lost.")
            case .closeIdle: Text("Quits Claude profiles with no chat working or waiting on you.")
            }
        }
        .sheet(isPresented: $showClean) {
            CleanSheet(targets: store.system?.cleanable ?? []) { ids in send(.cleanDisk(ids)) }
                .presentationDetents([.medium])
        }
    }

    @ViewBuilder func content(_ h: SystemHealth) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(h.reasons, id: \.self) { r in
                HStack(spacing: 6) {
                    Text("▸").foregroundStyle(color(h.level))
                    Text(r).foregroundStyle(color(h.level))
                }
            }
        }
        .font(Theme.monoSmall)
        .padding(.bottom, h.reasons.isEmpty ? 0 : 6)

        VStack(alignment: .leading, spacing: 8) {
            gauge("memory", "\(gb(h.memUsed)) / \(gb(h.memTotal))" + (h.pressure == .ok ? "" : " · \(h.pressure.rawValue)"),
                  Double(h.memUsed) / Double(max(1, h.memTotal)), h.history.map { Double($0.memUsed) }, h.pressure)
            gauge("swap", h.swapTotal > 0 ? "\(gb(h.swapUsed)) / \(gb(h.swapTotal))" : "none",
                  h.swapTotal > 0 ? Double(h.swapUsed) / Double(h.swapTotal) : 0, h.history.map { Double($0.swapUsed) },
                  level(h, "swap"))
            gauge("cpu", String(format: "load %.1f · %d cores", h.load1, h.cores), min(1, h.load1 / Double(max(1, h.cores * 4))),
                  h.history.map(\.load1), level(h, "load"))
            gauge("disk", "\(gb(h.diskFree)) free", 1 - Double(h.diskFree) / Double(max(1, h.diskTotal)),
                  h.history.map { -Double($0.diskFree) }, level(h, "disk"))
            if h.thermal != "nominal" {
                Text("thermal \(h.thermal)").foregroundStyle(Theme.yellow)
            }
        }
        .font(Theme.monoSmall)
        .padding(.bottom, 6)

        SectionTitle("top apps", count: h.apps.count)
        VStack(spacing: 0) {
            ForEach(h.apps.prefix(10)) { a in appRow(a) }
        }
        .font(Theme.monoSmall)

        HStack(spacing: 10) {
            Button("close idle claude") { confirm = .closeIdle }
                .disabled(store.isPending(Keys.closeIdle))
            Button("free disk…") { showClean = true }
                .disabled(h.cleanable.isEmpty || store.isPending(Keys.clean))
            if store.isPending(Keys.closeIdle) || store.isPending(Keys.clean) { ProgressView().controlSize(.small) }
        }
        .buttonStyle(.outline)
        .font(Theme.monoSmall)
        .disabled(!store.canSend)
        .padding(.vertical, 10)

        Toggle(isOn: Binding(get: { autoPending ?? h.auto.enabled },
                             set: { on in autoPending = on; send(.setAutoAct(on)) })) {
            HStack(spacing: 6) {
                Text("▸").foregroundStyle(Theme.clay).fixedSize()
                Text("auto-act when critical")
            }
        }
        .font(Theme.monoSmall)
        .tint(Theme.clay)
        .frame(minHeight: 40)
        .disabled(!store.canSend)
        Text(autoSummary(h.auto) + " · change what it does in the mac app's settings")
            .font(Theme.monoTiny).foregroundStyle(.secondary)
            .padding(.leading, 14).padding(.bottom, 10)
    }

    func gauge(_ name: String, _ value: String, _ fraction: Double, _ trend: [Double], _ level: HealthLevel) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 0) {
                Text(name).foregroundStyle(.secondary).frame(minWidth: keyWidth, alignment: .leading)
                Text(value).foregroundStyle(level == .ok ? Color.primary : color(level)).lineLimit(1)
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                ProgressView(value: min(1, max(0, fraction)))
                    .tint(level == .ok ? Theme.clay : color(level))
                    .frame(width: 110)
                Sparkline(values: trend).frame(height: 16)
            }
            .padding(.leading, keyWidth)
        }
    }

    func appRow(_ a: AppUsage) -> some View {
        HStack(spacing: 8) {
            Text(a.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text(gb(a.rss)).monospacedDigit()
            Text("\(Int(a.cpu.rounded()))%").foregroundStyle(.secondary).frame(minWidth: 40, alignment: .trailing)
            Menu {
                if a.canQuit { Button("Quit", systemImage: "xmark.circle") { confirm = .quit(a) } }
                if a.canKill { Button("Kill", systemImage: "bolt.slash", role: .destructive) { confirm = .kill(a) } }
            } label: {
                if store.isPending(Keys.app(a.id)) { ProgressView().controlSize(.mini) } else { Image(systemName: "ellipsis.circle") }
            }
            .disabled(!store.canSend || (!a.canQuit && !a.canKill) || store.isPending(Keys.app(a.id)))
            .frame(minWidth: 28, minHeight: 36)
            .accessibilityLabel("Actions for \(a.name)")
        }
        .contextMenu {
            if a.canQuit { Button("Quit", systemImage: "xmark.circle") { confirm = .quit(a) } }
            if a.canKill { Button("Kill", systemImage: "bolt.slash", role: .destructive) { confirm = .kill(a) } }
        }
    }

    // MARK: Helpers

    var confirmTitle: String {
        switch confirm {
        case .quit(let a): "Quit \(a.name)?"
        case .kill(let a): "Kill \(a.name)?"
        case .closeIdle: "Close idle Claude windows?"
        case nil: ""
        }
    }

    func send(_ c: RemoteCommand) {
        Task {
            if let j = await store.perform(c), j.status == .done, !store.isDemo {
                store.toast = Toast(message: j.reason ?? "\(c.label) done", isError: false)
            }
        }
    }

    func level(_ h: SystemHealth, _ prefix: String) -> HealthLevel {
        h.reasons.contains { $0.hasPrefix(prefix) } ? h.level : .ok
    }

    func color(_ l: HealthLevel) -> Color {
        switch l { case .ok: Theme.green; case .warn: Theme.yellow; case .critical: Theme.red }
    }

    func label(_ l: HealthLevel) -> String {
        switch l { case .ok: "all good"; case .warn: "under pressure"; case .critical: "critical" }
    }

    func gb(_ b: Int64) -> String { String(format: "%.1f GB", Double(b) / 1e9) }

    func autoSummary(_ a: AutoActSummary) -> String {
        var what: [String] = []
        if a.closeIdleClaude { what.append("close idle claude") }
        if !a.quitApps.isEmpty {
            what.append("quit " + a.quitApps.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }.joined(separator: ", "))
        }
        if !a.cleanTargets.isEmpty { what.append("clean " + a.cleanTargets.joined(separator: ", ")) }
        let after = a.afterSeconds >= 60 ? "\(a.afterSeconds / 60) min" : "\(a.afterSeconds) s"
        return (what.isEmpty ? "nothing chosen" : what.joined(separator: " · ")) + " after \(after) critical"
    }
}

/// A line over the values, scaled to their own min and max.
private struct Sparkline: View {
    var values: [Double]

    var body: some View {
        GeometryReader { g in
            if values.count > 1, let lo = values.min(), let hi = values.max() {
                Path { p in
                    let span = max(hi - lo, abs(hi) * 0.02, 1e-9)
                    for (i, v) in values.enumerated() {
                        let pt = CGPoint(x: g.size.width * CGFloat(i) / CGFloat(values.count - 1),
                                         y: g.size.height * (1 - CGFloat((v - lo) / span)))
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                }
                .stroke(Theme.clay, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Pick what to delete, see the total, confirm.
private struct CleanSheet: View {
    let targets: [CleanTarget]
    let onClean: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var picked = Set<String>()
    @State private var confirming = false

    var total: Int64 { targets.filter { picked.contains($0.id) }.map { max(0, $0.bytes) }.reduce(0, +) }
    var totalText: String { String(format: "%.1f GB", Double(total) / 1e9) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(targets) { t in
                        Toggle(isOn: Binding(get: { picked.contains(t.id) },
                                             set: { on in if on { picked.insert(t.id) } else { picked.remove(t.id) } })) {
                            HStack {
                                Text(t.label)
                                Spacer()
                                Text(t.bytes < 0 ? "size unknown" : String(format: "%.1f GB", Double(t.bytes) / 1e9))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tint(Theme.clay)
                    }
                } footer: {
                    Text("Deleted permanently on the Mac. Caches are rebuilt when needed; the Trash can't be recovered.")
                }
            }
            .font(Theme.monoSmall)
            .navigationTitle("free disk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Delete \(totalText)", role: .destructive) { confirming = true }
                        .tint(Theme.red)
                        .disabled(picked.isEmpty)
                }
            }
            .confirmationDialog("Permanently delete \(totalText)?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    onClean(targets.map(\.id).filter(picked.contains))
                    dismiss()
                }
            }
        }
    }
}
