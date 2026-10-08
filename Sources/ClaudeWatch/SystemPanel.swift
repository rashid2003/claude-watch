import SwiftUI
import WatchCore

/// The "system" section: memory, swap, CPU and disk with their 30-minute trend, the heaviest apps,
/// and the actions that relieve the Mac (quit, kill, close idle Claude windows, free disk).
struct SystemPanel: View {
    @EnvironmentObject var model: WatchModel
    @State private var confirm: Pending?
    @State private var result: (ok: Bool, text: String)?
    @State private var busy = false
    @State private var showClean = false

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
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let h = model.health {
                    banner(h)
                    gauges(h)
                    apps(h)
                    actions(h)
                } else {
                    Text("Taking the first reading…").font(Theme.mono).foregroundStyle(.secondary).padding(.vertical, 12)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible, presenting: confirm) { p in
            switch p {
            case .quit(let a): Button("Quit \(a.name)") { run(.quitApp(a.id)) }
            case .kill(let a): Button("Kill \(a.name)", role: .destructive) { run(.kill(a.mainPid)) }
            case .closeIdle: Button("Close idle windows") { run(.closeIdleClaude) }
            }
        } message: { p in
            switch p {
            case .quit: Text("Asks the app to quit, like ⌘Q. It may ask to save first.")
            case .kill(let a): Text("Kills pid \(a.mainPid) immediately. Unsaved work in it is lost.")
            case .closeIdle: Text("Quits Claude profiles with no chat working or waiting on you.")
            }
        }
        .sheet(isPresented: $showClean) {
            CleanSheet(targets: model.health?.cleanable ?? []) { ids in run(.clean(ids)) }
        }
    }

    var confirmTitle: String {
        switch confirm {
        case .quit(let a): "Quit \(a.name)?"
        case .kill(let a): "Kill \(a.name)?"
        case .closeIdle: "Close idle Claude windows?"
        case nil: ""
        }
    }

    func run(_ a: SystemAction) {
        busy = true
        model.runSystem(a) { ok, text in
            busy = false
            result = (ok, text)
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { if result?.text == text { result = nil } }
        }
    }

    // MARK: Parts

    func banner(_ h: SystemHealth) -> some View {
        Panel {
            HStack(spacing: 8) {
                Circle().fill(SystemStyle.color(h.level)).frame(width: 9, height: 9)
                Text(SystemStyle.label(h.level)).fontWeight(.semibold)
                Spacer()
                Text("updated \(h.at.formatted(date: .omitted, time: .standard))").foregroundStyle(.secondary)
            }
            .font(Theme.mono)
            ForEach(h.reasons, id: \.self) { Text("▸ " + $0).font(Theme.mono).foregroundStyle(SystemStyle.color(h.level)) }
            if h.reasons.isEmpty { Text("Memory, swap, CPU, disk and temperature are all fine.").font(Theme.monoSmall).foregroundStyle(.secondary) }
        }
    }

    func gauges(_ h: SystemHealth) -> some View {
        Panel(title: "resources") {
            gauge("memory", "\(SystemText.gb(h.memUsed)) of \(SystemText.gb(h.memTotal)) · pressure \(h.pressure.rawValue)",
                  Double(h.memUsed) / Double(max(1, h.memTotal)), h.history.map { Double($0.memUsed) }, level: h.pressure)
            gauge("swap", h.swapTotal > 0 ? "\(SystemText.gb(h.swapUsed)) of \(SystemText.gb(h.swapTotal))" : "none",
                  h.swapTotal > 0 ? Double(h.swapUsed) / Double(h.swapTotal) : 0, h.history.map { Double($0.swapUsed) },
                  level: h.reasons.contains { $0.hasPrefix("swap") } ? h.level : .ok)
            gauge("cpu", String(format: "load %.1f · %d cores", h.load1, h.cores), min(1, h.load1 / Double(max(1, h.cores * 4))),
                  h.history.map(\.load1), level: h.reasons.contains { $0.hasPrefix("load") } ? h.level : .ok)
            gauge("disk", "\(SystemText.gb(h.diskFree)) free of \(SystemText.gb(h.diskTotal))",
                  1 - Double(h.diskFree) / Double(max(1, h.diskTotal)), h.history.map { -Double($0.diskFree) },
                  level: h.reasons.contains { $0.hasPrefix("disk") } ? h.level : .ok)
            if h.thermal != "nominal" { Text("thermal \(h.thermal)").font(Theme.mono).foregroundStyle(Theme.yellow) }
        }
    }

    func gauge(_ name: String, _ value: String, _ fraction: Double, _ trend: [Double], level: HealthLevel) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(name).fontWeight(.semibold).frame(width: 64, alignment: .leading)
                Text(value).foregroundStyle(level == .ok ? Color.primary : SystemStyle.color(level))
                Spacer()
            }
            .font(Theme.mono)
            HStack(spacing: 12) {
                ProgressView(value: min(1, max(0, fraction))).tint(level == .ok ? Theme.clay : SystemStyle.color(level))
                    .frame(maxWidth: 220)
                Sparkline(values: trend).frame(height: 22)
            }
        }
        .padding(.vertical, 3)
    }

    func apps(_ h: SystemHealth) -> some View {
        Panel(title: "top apps", count: h.apps.count) {
            ForEach(h.apps) { a in
                HStack(spacing: 10) {
                    Text(a.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                        .help(a.id)
                    Text(SystemText.gb(a.rss)).frame(width: 70, alignment: .trailing)
                    Text("\(Int(a.cpu.rounded()))%").frame(width: 44, alignment: .trailing).foregroundStyle(.secondary)
                    Text(a.processes > 1 ? "×\(a.processes)" : "").frame(width: 34, alignment: .trailing).foregroundStyle(.secondary)
                    Button("Quit") { confirm = .quit(a) }.disabled(!a.canQuit || busy)
                    Button("Kill") { confirm = .kill(a) }.disabled(!a.canKill || busy)
                }
                .font(Theme.mono)
                .controlSize(.small)
            }
        }
    }

    func actions(_ h: SystemHealth) -> some View {
        Panel(title: "actions") {
            HStack {
                Button("Close idle Claude windows…") { confirm = .closeIdle }
                Button("Free disk…") { showClean = true }.disabled(h.cleanable.isEmpty)
                if busy { ProgressView().controlSize(.small) }
            }
            .disabled(busy)
            if let r = result {
                Text(r.text).font(Theme.mono).foregroundStyle(r.ok ? Theme.green : Theme.red)
            }
            Divider()
            HStack {
                Text(SystemStyle.autoSummary(h.auto)).font(Theme.monoSmall).foregroundStyle(.secondary)
                Spacer()
                Button("Settings…") { model.section = .settings }.controlSize(.small)
            }
        }
    }
}

enum SystemStyle {
    static func color(_ l: HealthLevel) -> Color {
        switch l { case .ok: Theme.green; case .warn: Theme.yellow; case .critical: Theme.red }
    }

    static func label(_ l: HealthLevel) -> String {
        switch l { case .ok: "all good"; case .warn: "under pressure"; case .critical: "critical" }
    }

    static func autoSummary(_ a: AutoActSummary) -> String {
        guard a.enabled else { return "auto-act off" }
        var what: [String] = []
        if a.closeIdleClaude { what.append("close idle Claude") }
        if !a.quitApps.isEmpty { what.append("quit " + a.quitApps.map(shortName).joined(separator: ", ")) }
        if !a.cleanTargets.isEmpty { what.append("clean " + a.cleanTargets.joined(separator: ", ")) }
        let after = a.afterSeconds >= 60 ? "\(a.afterSeconds / 60) min" : "\(a.afterSeconds) s"
        return "auto-act on · " + (what.isEmpty ? "nothing chosen yet" : what.joined(separator: " · ")) + " after \(after) critical"
    }

    static func shortName(_ id: String) -> String { ((id as NSString).lastPathComponent as NSString).deletingPathExtension }
}

/// A line over the values, scaled to their own min and max.
struct Sparkline: View {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Free disk space").font(Theme.mono.weight(.semibold))
            ForEach(targets) { t in
                Toggle(isOn: Binding(get: { picked.contains(t.id) }, set: { on in if on { picked.insert(t.id) } else { picked.remove(t.id) } })) {
                    HStack {
                        Text(t.label)
                        Spacer()
                        Text(t.bytes < 0 ? "size unknown" : SystemText.gb(t.bytes)).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Deleted permanently. Caches are rebuilt when needed; the Trash can't be recovered.")
                .font(Theme.monoSmall).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Delete \(SystemText.gb(total))", role: .destructive) { confirming = true }
                    .disabled(picked.isEmpty)
            }
        }
        .font(Theme.mono)
        .padding(20)
        .frame(width: 420)
        .confirmationDialog("Permanently delete \(SystemText.gb(total))?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                onClean(targets.map(\.id).filter(picked.contains))
                dismiss()
            }
        }
    }
}
