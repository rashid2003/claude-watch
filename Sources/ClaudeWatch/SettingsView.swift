import AppKit
import ServiceManagement
import SwiftUI
import WatchCore

/// Edits config.json (through `WatchModel.updateConfig`). Used by the main window's Settings
/// section and the standard Settings scene (⌘,).
struct SettingsView: View {
    @EnvironmentObject var model: WatchModel
    @State private var login = LoginItem()

    var cfg: Config { model.config }

    /// A binding that saves on set.
    func bind<T>(_ key: WritableKeyPath<Config, T>, clamp: ((T) -> T)? = nil) -> Binding<T> {
        Binding(get: { model.config[keyPath: key] },
                set: { v in
                    let v = clamp?(v) ?? v
                    model.updateConfig { $0[keyPath: key] = v }
                })
    }

    var body: some View {
        Form {
            if let e = model.configError {
                Section { Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.red) }
            }

            Section {
                Toggle("Show in menu bar", isOn: Binding(get: { cfg.showInMenuBar }, set: { model.setShowInMenuBar($0) }))
                    .disabled(cfg.showInMenuBar && !cfg.showInDock)
                Toggle("Show in Dock", isOn: Binding(get: { cfg.showInDock }, set: { model.setShowInDock($0) }))
                    .disabled(cfg.showInDock && !cfg.showInMenuBar)
                LabeledContent {
                    Toggle("", isOn: Binding(get: { login.enabled }, set: { login.set($0) })).labelsHidden()
                } label: {
                    Text("Launch at login")
                    Text(login.statusText).foregroundStyle(login.needsApproval ? Theme.yellow : .secondary)
                }
                if login.needsApproval {
                    Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                }
                if let e = login.error { Text(e).foregroundStyle(Theme.red).font(Theme.monoSmall) }
            } header: { header("appearance") } footer: {
                note("At least one of the menu bar item and the Dock icon stays on.")
            }

            Section {
                Picker("Default retry mode", selection: bind(\.defaultRetryMode)) {
                    ForEach(RetryMode.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                }
                .pickerStyle(.segmented)
                CommitTextField(label: "Retry message", value: bind(\.retryMessage))
                number("Retry delay", bind(\.retryDelaySeconds, clamp: { min(3600, max(0, $0)) }), unit: "s")
                number("Max attempts", bind(\.maxAttempts, clamp: { min(20, max(1, $0)) }), unit: "")
                number("Max failure age", bind(\.maxFailureAgeHours, clamp: { min(24 * 14, max(0.5, $0)) }), unit: "h")
                number("Warn before cap", bind(\.warnBeforeCapMinutes, clamp: { min(600, max(0, $0)) }), unit: "min")
                number("Poll every", bind(\.pollSeconds, clamp: { min(600, max(3, $0)) }), unit: "s")
            } header: { header("retries") } footer: {
                note("UI types the message into the Claude window; CLI resumes the chat with the claude CLI. "
                     + "Accounts can override the mode in Overview.")
            }

            Section {
                number("Disk warning below", bind(\.system.diskWarnGB, clamp: { min(2000, max(2, $0)) }), unit: "GB")
                number("Disk critical below", bind(\.system.diskCriticalGB, clamp: { min(cfg.system.diskWarnGB - 1, max(1, $0)) }), unit: "GB")
                Toggle("Act automatically when critical", isOn: bind(\.system.auto.enabled))
                Group {
                    number("After critical for", bind(\.system.auto.afterSeconds, clamp: { min(3600, max(30, $0)) }), unit: "s")
                    Toggle("Close idle Claude windows", isOn: bind(\.system.auto.closeIdleClaude))
                    LabeledContent("Quit these apps") {
                        VStack(alignment: .trailing, spacing: 4) {
                            ForEach(cfg.system.auto.quitApps, id: \.self) { id in
                                HStack(spacing: 6) {
                                    Text(appLabel(id))
                                    Button { model.updateConfig { $0.system.auto.quitApps.removeAll { $0 == id } } } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                            Menu("Add app") {
                                ForEach(addableApps, id: \.self) { id in
                                    Button(appLabel(id)) { model.updateConfig { $0.system.auto.quitApps.append(id) } }
                                }
                            }
                            .fixedSize()
                            .disabled(addableApps.isEmpty)
                        }
                    }
                    Toggle("Force-quit apps still open after 30 s", isOn: bind(\.system.auto.forceIfStuck))
                    LabeledContent("When disk is critical, clean") {
                        VStack(alignment: .trailing, spacing: 2) {
                            ForEach(DiskCleaner.ids.filter { $0 != "trash" }, id: \.self) { id in
                                Toggle(DiskCleaner.labels[id] ?? id, isOn: Binding(
                                    get: { cfg.system.auto.cleanTargets.contains(id) },
                                    set: { on in model.updateConfig { c in
                                        c.system.auto.cleanTargets.removeAll { $0 == id }
                                        if on { c.system.auto.cleanTargets.append(id) }
                                    } }))
                            }
                        }
                    }
                }
                .disabled(!cfg.system.auto.enabled)
            } header: { header("system health") } footer: {
                note("Off by default. Session Watch acts only after the Mac has stayed critical for the delay, once per "
                     + "episode, then tells you (and the iPhone) what it did. Apps are asked to quit like ⌘Q.")
            }

            Section {
                Toggle("Enabled", isOn: bind(\.bridgeEnabled))
                number("Port", bind(\.bridgePort, clamp: { min(65535, max(1024, $0)) }), unit: "", grouping: false)
                Toggle("Require Tailscale owner", isOn: bind(\.requireTailnetOwner))
                Toggle("Connect through relay", isOn: bind(\.relayEnabled))
                if cfg.relayEnabled && cfg.bridgeEnabled {
                    LabeledContent("Relay") { relayStatus }
                }
                Toggle("Keep awake when paired", isOn: bind(\.keepAwakeWhenPaired))
                Toggle("Only on AC power", isOn: bind(\.keepAwakeOnlyOnAC))
                    .disabled(!cfg.keepAwakeWhenPaired)
                if bridgeNeedsRestart {
                    HStack {
                        Text("Restart Session Watch to apply the bridge change.").foregroundStyle(Theme.yellow)
                        Spacer()
                        Button("Restart now") { model.relaunch() }
                    }
                }
            } header: { header("iphone bridge") } footer: {
                note("Only phones signed into this Mac's Tailscale account can connect when the owner check is on. "
                     + "The relay lets a paired iPhone reach this Mac without Tailscale; everything through it is "
                     + "end-to-end encrypted with a key from the pairing QR. Pair again after turning it on.")
            }

            Section {
                LabeledContent("Accessibility") {
                    HStack {
                        Text(model.trusted ? "✓ granted" : "✗ not granted")
                            .foregroundStyle(model.trusted ? Theme.green : Theme.red)
                        if !model.trusted { Button("Grant") { UIRetry.requestTrust() } }
                    }
                }
                HStack {
                    Button("Open config file") { NSWorkspace.shared.open(Paths.config) }
                    Button("Open logs folder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.logs]) }
                }
            } header: { header("files & access") }
        }
        .formStyle(.grouped)
        .font(Theme.mono)
        .onAppear { login.refresh(); model.trusted = UIRetry.isTrusted }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            login.refresh(); model.trusted = UIRetry.isTrusted
        }
    }

    @ViewBuilder var relayStatus: some View {
        let _ = model.bridgeTick   // redraw on relay status changes
        switch model.bridge?.relayStatus ?? .off {
        case .connected: Text("● connected").foregroundStyle(Theme.green)
        case .connecting: Text("◐ connecting").foregroundStyle(Theme.yellow)
        case .off: Text("○ off").foregroundStyle(.secondary)
        case .failed(let why): Text("✗ \(why)").foregroundStyle(Theme.red).lineLimit(2)
        }
    }

    var bridgeNeedsRestart: Bool {
        cfg.bridgeEnabled != model.bridgeAtLaunch.enabled
            || (cfg.bridgeEnabled && cfg.bridgePort != model.bridgeAtLaunch.port)
    }

    /// Display name for an auto-quit entry: the running app's name, else the bundle or process name.
    func appLabel(_ id: String) -> String {
        model.health?.apps.first { $0.id == id }?.name ?? SystemStyle.shortName(id)
    }

    /// Current top apps not yet in the auto-quit list. Loose processes are added by name (pids change).
    var addableApps: [String] {
        let have = Set(cfg.system.auto.quitApps)
        return (model.health?.apps ?? []).compactMap { a -> String? in
            if a.id.hasPrefix("claude:") { return nil }
            return a.id.hasPrefix("pid:") ? a.name : a.id
        }.filter { !have.contains($0) }
    }

    func header(_ t: String) -> some View { Text(t).font(Theme.mono.weight(.semibold)).foregroundStyle(Theme.clay) }
    func note(_ t: String) -> some View { Text(t).font(Theme.monoSmall).foregroundStyle(.secondary) }

    /// A number field that saves on Return or when it loses focus.
    func number(_ label: String, _ value: Binding<Int>, unit: String, grouping: Bool = true) -> some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                TextField(label, value: value, format: IntegerFormatStyle<Int>().grouping(grouping ? .automatic : .never))
                    .labelsHidden().multilineTextAlignment(.trailing).frame(width: 90)
                Stepper("", value: value).labelsHidden()
                Text(unit).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
            }
        }
    }

    func number(_ label: String, _ value: Binding<Double>, unit: String) -> some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                TextField(label, value: value, format: .number)
                    .labelsHidden().multilineTextAlignment(.trailing).frame(width: 90)
                Stepper("", value: value).labelsHidden()
                Text(unit).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
            }
        }
    }
}

/// A text field that saves on Return or when it loses focus, never while typing, and never empty
/// (an empty retry message would send nothing).
private struct CommitTextField: View {
    let label: String
    @Binding var value: String
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(label, text: $draft)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, f in if !f { commit() } }
            .onChange(of: value, initial: true) { _, v in if !focused { draft = v } }
    }

    func commit() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { draft = value } else if t != value { value = t }
    }
}

/// "Launch at login" through SMAppService (the app itself as a login item).
struct LoginItem {
    private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    private(set) var error: String?

    var enabled: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }
    var statusText: String {
        switch status {
        case .enabled: "on"
        case .requiresApproval: "needs approval in System Settings › Login Items"
        case .notRegistered: "off"
        case .notFound: "unavailable for this copy of the app"
        @unknown default: "unknown"
        }
    }

    mutating func refresh() { status = SMAppService.mainApp.status }

    mutating func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = (on ? "Couldn't turn on: " : "Couldn't turn off: ") + error.localizedDescription
        }
        refresh()
    }
}
