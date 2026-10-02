import AppKit
import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import WatchBridge
import WatchCore

extension ChatFeed: MessageSource {}

/// Connects the iPhone bridge to the Monitor: answers its reads, runs its commands, and turns
/// events into push notifications.
final class BridgeController: BridgeHandler, @unchecked Sendable {
    let monitor: Monitor
    let server: BridgeServer
    let broker = PromptBroker(path: Paths.bridgeSocket)
    let pusher = Pusher(key: APNsKey.load())
    let runner: HeadlessRunner
    private let lock = NSLock()
    private var latest: Snapshot?
    private var touched: [String: Date] = [:]          // chats the phone acted on -> when
    private var lastActivity: [String: SessionStatus.Activity] = [:]
    private var knownPrompts = Set<String>()
    private var firstSnapshot = true
    private var sleepAssertion: IOPMAssertionID = 0
    private let work = DispatchQueue(label: "claude-watch.remote-actions")
    /// Called on the main queue when devices, pairing or status change (menu UI).
    var onChange: (() -> Void)?

    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }

    /// Refuses tailnet peers that aren't signed into this Mac's Tailscale account.
    let owner = TailnetOwner()

    init(monitor: Monitor) {
        self.monitor = monitor
        let cfg = monitor.config
        server = BridgeServer(port: UInt16(clamping: cfg.bridgePort), devices: DeviceStore(url: Paths.devices),
                              audit: AuditLog(url: Paths.remoteLog), macName: Host.current().localizedName ?? "Mac",
                              handler: nil, hosts: { ["127.0.0.1"] + TailscaleAddresses.current() })
        let socket = Paths.bridgeSocket
        let tool = Self.cliPath()
        runner = HeadlessRunner(promptTool: { sid in tool.map { [$0, "prompt-tool", "--socket", socket, "--session", sid] } })
        server.handler = self
        if cfg.requireTailnetOwner { server.peerCheck = { [owner] in owner.allows($0) } }
        server.onDevicesChanged = { [weak self] in self?.devicesChanged() }
        server.pairing.onClose = { [weak self] in DispatchQueue.main.async { self?.onChange?() } }
        broker.describe = { [weak self] id in
            guard let s = self?.session(id) else { return nil }
            return (s.info.title, s.info.profileId)
        }
        broker.onChange = { [weak self] _ in self?.republish() }
        pusher.onInvalidToken = { [weak self] id in self?.server.devices.update(id) { $0.apnsToken = nil } }
        runner.onExit = { [weak self] sid, _ in self?.broker.clear(chatId: sid); self?.monitor.refreshNow() }
    }

    /// The claude-watch CLI (it serves the prompt tool): next to the app binary, else ~/.local/bin.
    static func cliPath() -> String? {
        let fm = FileManager.default
        let sibling = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("claude-watch").path
        for p in [sibling, Paths.home.appendingPathComponent(".local/bin/claude-watch").path].compactMap({ $0 })
        where fm.isExecutableFile(atPath: p) { return p }
        return nil
    }

    func start() {
        guard monitor.config.bridgeEnabled else { return }
        try? broker.start()
        server.start()
        // Development: pair the Simulator without the menu (CLAUDE_WATCH_DEV_PAIR_CODE=123456).
        if let code = ProcessInfo.processInfo.environment["CLAUDE_WATCH_DEV_PAIR_CODE"], code.count == 6 {
            server.pairing.open(code: code, lifetime: 3600)
        }
    }

    func stop() {
        server.stop()
        broker.stop()
        setKeepAwake(false)
    }

    // MARK: Snapshot fan-out

    func update(_ s: Snapshot) {
        let merged = merge(s)
        lock.withLock { latest = s }
        server.publish(snapshot: merged)
        notifyTransitions(merged)
        evaluateKeepAwake()
    }

    private func republish() {
        guard let s = lock.withLock({ latest }) else { return }
        let merged = merge(s)
        server.publish(snapshot: merged)
        notifyTransitions(merged)
    }

    /// Adds headless prompts; a chat with one counts as waiting.
    private func merge(_ s: Snapshot) -> Snapshot {
        let extra = broker.prompts
        guard !extra.isEmpty else { return s }
        var m = s
        m.prompts += extra
        let waiting = Set(extra.map(\.chatId))
        for a in m.accounts.indices {
            for i in m.accounts[a].sessions.indices where waiting.contains(m.accounts[a].sessions[i].id) {
                m.accounts[a].sessions[i].activity = .waiting
            }
        }
        return m
    }

    private func session(_ id: String) -> SessionStatus? {
        lock.withLock { latest }?.accounts.lazy.flatMap(\.sessions).first { $0.id == id }
    }

    private func profile(_ id: String) -> Profile? {
        lock.withLock { latest }?.profiles.first { $0.id == id } ?? monitor.profile(id: id)
    }

    // MARK: BridgeHandler reads

    func snapshot() -> Snapshot? { lock.withLock { latest }.map(merge) }

    func status(for device: Device) -> BridgeStatus {
        var w: [String] = []
        if !UIRetry.isTrusted { w.append("Accessibility permission is missing on the Mac, so prompts can't be answered and new chats can't be started.") }
        if !pusher.isConfigured { w.append("Push notifications aren't set up on the Mac yet (claude-watch set-apns-key).") }
        if let e = pusher.lastError { w.append(e) }
        if TailscaleAddresses.current().isEmpty { w.append("Tailscale isn't connected on the Mac; only this Mac can reach the bridge.") }
        if let e = server.lastError { w.append(e) }
        if monitor.config.requireTailnetOwner && owner.unavailable {
            w.append("The Tailscale CLI isn't available, so the bridge can't check that connecting devices are yours.")
        }
        if let r = owner.lastRefused { w.append(r) }
        let profiles = lock.withLock { latest }?.profiles ?? []
        let noToken = profiles.filter { TokenStore.get($0.id) == nil }.map(\.name)
        if !noToken.isEmpty {
            w.append("No CLI token for \(noToken.joined(separator: ", ")): replies there are typed into the desktop window instead.")
        }
        if Self.cliPath() == nil { w.append("claude-watch CLI not found, so background replies can't ask you about tools.") }
        return BridgeStatus(macName: server.macName, version: Self.version, warnings: w, pushConfigured: pusher.isConfigured,
                            deviceId: device.id, notify: device.notify)
    }

    private func transcript(_ chatId: String) -> URL? {
        guard let cli = session(chatId)?.info.cliSessionId else { return nil }
        return monitor.sync { $0.transcriptURL(cliSessionId: cli) }
    }

    func messages(chatId: String, before: Int?, limit: Int) -> MessagesPage? {
        transcript(chatId).map { ChatFeed.page(url: $0, before: before, limit: limit) }
    }

    func subscribe(chatId: String) -> (source: MessageSource, initial: [ChatMessage])? {
        guard let url = transcript(chatId) else { return nil }
        let feed = ChatFeed(url: url)
        return (feed, feed.poll())
    }

    func folders(profileId: String) -> [FolderSuggestion] {
        guard let s = lock.withLock({ latest }) else { return [] }
        let members = s.account(forProfile: profileId)?.memberProfileIds ?? [profileId]
        var best: [String: Date] = [:]
        let index = SessionIndex()
        for p in s.profiles where members.contains(p.id) {
            for info in index.sessions(for: p) where !info.cwd.isEmpty {
                best[info.cwd] = max(best[info.cwd] ?? .distantPast, info.lastActivityAt)
            }
        }
        return best.filter { FileManager.default.fileExists(atPath: $0.key) }
            .map { FolderSuggestion(cwd: $0.key, lastUsedAt: $0.value) }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }.prefix(40).map { $0 }
    }

    func usage(profileId: String) -> [UsageSample] {
        guard let s = lock.withLock({ latest }), let a = s.account(forProfile: profileId) else { return [] }
        let org = a.accountUuid?.split(separator: "/").last.map(String.init)
        let since = Date().addingTimeInterval(-7 * 86400)
        return s.profiles.filter { a.memberProfileIds.contains($0.id) }
            .map { UsageHistoryReader.read(profile: $0).filter { (org == nil || $0.org == org) && $0.t > since } }
            .max { ($0.last?.t ?? .distantPast) < ($1.last?.t ?? .distantPast) } ?? []
    }

    // MARK: Commands

    func check(_ command: BridgeCommand) -> (Int, String)? {
        switch command {
        case .reply(let id, _):
            guard let s = session(id) else { return (404, "That chat isn't listed on the Mac any more") }
            if s.activity == .working || runner.isRunning(sessionId: id) { return (409, HeadlessRunner.busyMessage) }
        case .answer(_, let pid, _):
            guard snapshot()?.prompts.contains(where: { $0.id == pid }) == true else { return (409, "That prompt is no longer pending") }
        case .stop(let id):
            guard session(id) != nil else { return (404, "That chat isn't listed on the Mac any more") }
        case .newChat(let p, let cwd, let prompt):
            guard profile(p) != nil else { return (404, "Unknown account") }
            guard FileManager.default.fileExists(atPath: cwd) else { return (400, "No such folder on the Mac: \(cwd)") }
            if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (400, "Write a prompt first") }
        case .retry(let item), .cancelRetry(let item):
            guard lock.withLock({ latest })?.queue.contains(where: { $0.id == item }) == true else { return (404, "Not in the retry queue") }
        default: break
        }
        return nil
    }

    func perform(_ command: BridgeCommand, device: Device, done: @escaping (JobStatus, String?) -> Void) {
        switch command {
        case .reply(let id, _), .answer(let id, _, _), .stop(let id): lock.withLock { touched[id] = Date() }
        default: break
        }
        work.async { [self] in
            let (status, reason) = run(command)
            done(status, reason)
            monitor.refreshNow()
        }
    }

    private func result(_ r: Result<String, RetryError>) -> (JobStatus, String?) {
        switch r {
        case .success(let m): return (.done, m)
        case .failure(let e): return (e.blocked ? .blocked : .failed, e.message)
        }
    }

    /// Runs one command on the remote-actions queue (may block for seconds).
    private func run(_ command: BridgeCommand) -> (JobStatus, String?) {
        switch command {
        case .reply(let id, let text):
            guard let s = session(id), let p = profile(s.info.profileId) else { return (.failed, "Chat not found") }
            if TokenStore.get(p.id) == nil {
                return result(UIRetry.type(message: text, session: s.info, profile: p).map { _ in "Typed into the \(p.name) window" })
            }
            return result(runner.reply(text, session: s.info, profile: p, activity: s.activity)
                .map { "Sent in the background (pid \($0))" })

        case .answer(let chatId, let promptId, let decision):
            guard let prompt = snapshot()?.prompts.first(where: { $0.id == promptId }) else { return (.failed, "Prompt no longer pending") }
            if prompt.source == .headless {
                return broker.answer(id: promptId, allow: decision != .deny) ? (.done, nil) : (.failed, "Prompt no longer pending")
            }
            guard prompt.kind == .permission else { return (.failed, "Answer this question on the Mac") }
            guard let s = session(chatId), let p = profile(s.info.profileId) else { return (.failed, "Chat not found") }
            let r = DesktopActions.answer(decision: decision, session: s.info, profile: p)
            guard case .success = r else { return result(r) }
            // Pressed: confirm the prompt went away.
            for _ in 0..<10 {
                usleep(1_000_000)
                monitor.refreshNow()
                usleep(300_000)
                if snapshot()?.prompts.contains(where: { $0.id == promptId }) != true { return (.done, nil) }
            }
            return (.failed, "Pressed the button, but the prompt is still showing on the Mac")

        case .stop(let id):
            if runner.stop(sessionId: id) { return (.done, "Stopped the background run") }
            guard let s = session(id), let p = profile(s.info.profileId) else { return (.failed, "Chat not found") }
            return result(DesktopActions.stop(session: s.info, profile: p))

        case .newChat(let pid, let cwd, let prompt):
            guard let p = profile(pid) else { return (.failed, "Unknown account") }
            return result(DesktopActions.newChat(profile: p, cwd: cwd, prompt: prompt))

        case .retry(let itemId):
            guard lock.withLock({ latest })?.queue.contains(where: { $0.id == itemId }) == true else { return (.failed, "Not in the queue") }
            monitor.perform { $0.engine.request(.item(itemId)); $0.refreshNow() }
            return (.done, "Sending continue now")

        case .cancelRetry(let itemId):
            monitor.perform { $0.engine.request(.dismiss(itemId)); $0.refreshNow() }
            return (.done, nil)

        case .setMode(let pid, let mode):
            monitor.setRetryMode(mode, for: pid)
            return (.done, nil)

        case .move(let sid, let toId):
            guard let snap = lock.withLock({ latest }), let s = session(sid) else { return (.failed, "Chat not found") }
            if s.activity == .working || s.activity == .waiting { return (.failed, "Can't move a chat while it's working or waiting on you") }
            let parts = s.info.folder.split(separator: "/").map(String.init)
            guard parts.count == 2, let to = snap.locations.first(where: { $0.id == toId }) else { return (.failed, "Unknown destination") }
            let fromId = s.info.profileId + "/" + parts[0] + "/" + parts[1]
            let from = snap.locations.first { $0.id == fromId }
                ?? ChatLocation(profileId: s.info.profileId, accountUuid: parts[0], orgUuid: parts[1])
            guard monitor.requestMove(sessionId: sid, title: s.info.title, from: from, to: to) != nil else {
                return (.failed, "This chat already has a move pending")
            }
            return (.done, "Queued. Restart the windows to finish the move.")

        case .undoMove(let id):
            return monitor.undoMove(id) != nil ? (.done, "Undo queued. Restart the windows to finish.") : (.failed, "Can't undo that move")

        case .cancelMove(let id):
            monitor.cancelMove(id)
            return (.done, nil)

        case .restartMoves:
            let ids = Set((lock.withLock { latest }?.moves ?? []).filter { $0.status == .pending }.map(\.id))
            let (stuck, finished, _) = monitor.restartAndRunMoves(only: ids)
            if !stuck.isEmpty { return (.failed, "Couldn't quit: " + stuck.map(\.name).joined(separator: ", ")) }
            return (.done, "\(finished.filter { $0.status == .done }.count) moved")
        }
    }

    // MARK: Push

    private func push(_ note: PushNote, _ event: NotifyEvent) {
        guard pusher.isConfigured else { return }
        for d in server.devices.all where d.wants(event) { pusher.send(note, to: d) }
    }

    private func accountName(_ s: Snapshot, _ profileId: String) -> String {
        s.account(forProfile: profileId)?.profile.name ?? profileId
    }

    private func notifyTransitions(_ s: Snapshot) {
        var newPrompts: [PendingPrompt] = []
        var changes: [(SessionStatus, SessionStatus.Activity?)] = []
        lock.withLock {
            let ids = Set(s.prompts.map(\.id))
            newPrompts = s.prompts.filter { !knownPrompts.contains($0.id) }
            knownPrompts = ids
            for sess in s.accounts.flatMap(\.sessions) {
                let before = lastActivity[sess.id]
                lastActivity[sess.id] = sess.activity
                if before != sess.activity { changes.append((sess, before)) }
            }
            touched = touched.filter { Date().timeIntervalSince($0.value) < 86400 }
        }
        if lock.withLock({ let f = firstSnapshot; firstSnapshot = false; return f }) { return }

        for p in newPrompts {
            let title = accountName(s, p.profileId) + " · " + p.chatTitle
            let body = p.kind == .question ? p.summary : "\(p.toolName): \(p.summary)"
            push(PushNote(category: p.kind == .question ? "CHAT" : "PROMPT", title: title, body: body,
                          threadId: p.chatId, collapseId: "prompt-" + p.chatId,
                          userInfo: ["chatId": p.chatId, "promptId": p.id, "profileId": p.profileId]), .prompt)
        }
        let recent = lock.withLock { touched }
        for (sess, before) in changes where recent[sess.id] != nil {
            let info = ["chatId": sess.id, "profileId": sess.info.profileId]
            let title = accountName(s, sess.info.profileId) + " · " + sess.info.title
            if sess.activity == .idle, before == .working || before == .waiting {
                push(PushNote(category: "CHAT", title: title, body: "Claude finished its turn.", threadId: sess.id,
                              collapseId: "chat-" + sess.id, userInfo: info), .finished)
            } else if sess.activity == .failed, before != .failed {
                let why = sess.tail.lastRateLimit?.text ?? sess.info.desktopError ?? "The chat stopped with an error."
                push(PushNote(category: "CHAT", title: title, body: why, threadId: sess.id,
                              collapseId: "chat-" + sess.id, userInfo: info), .failed)
            }
        }
    }

    /// Account-level events the Mac already notifies about, forwarded to the phone.
    func event(_ e: WatchEvent) {
        let note: PushNote?
        switch e {
        case .accountFree(let p):
            note = PushNote(category: "ACCOUNT", title: "\(p.name) is free", body: "Nothing running. Ready for the next task.",
                            collapseId: "acct-" + p.id, userInfo: ["profileId": p.id])
        case .limitReset(let p):
            note = PushNote(category: "ACCOUNT", title: "\(p.name) limit reset", body: "The account can be used again.",
                            collapseId: "acct-" + p.id, userInfo: ["profileId": p.id])
        case .capSoon(let p, let k, let at):
            note = PushNote(category: "ACCOUNT", title: "\(p.name) nearing its \(k == .weekly ? "weekly" : "5-hour") limit",
                            body: "At this pace it hits the cap in ~\(Fmt.duration(at.timeIntervalSinceNow)).",
                            collapseId: "acct-" + p.id, userInfo: ["profileId": p.id])
        default: note = nil
        }
        if let note { push(note, .account) }
    }

    // MARK: Devices, pairing, keep-awake

    private func devicesChanged() {
        evaluateKeepAwake()
        DispatchQueue.main.async { self.onChange?() }
    }

    /// The QR payload for a fresh pairing code (hosts: MagicDNS name, then tailnet IPs, then loopback).
    func openPairing() -> PairingPayload {
        let code = server.pairing.open()
        var hosts: [String] = []
        if let name = TailscaleAddresses.magicDNSName() { hosts.append(name) }
        hosts += TailscaleAddresses.current()
        hosts.append("127.0.0.1")
        return PairingPayload(macName: server.macName, hosts: hosts, port: Int(server.port), code: code)
    }

    private func evaluateKeepAwake() {
        let cfg = monitor.config
        let onAC = (IOPSGetProvidingPowerSourceType(nil)?.takeUnretainedValue() as String?) == kIOPMACPowerKey
        setKeepAwake(cfg.keepAwakeWhenPaired && !server.devices.all.isEmpty && (onAC || !cfg.keepAwakeOnlyOnAC))
    }

    private func setKeepAwake(_ on: Bool) {
        lock.withLock {
            if on, sleepAssertion == 0 {
                IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                            "ClaudeWatch: keep the Mac reachable from the paired iPhone" as CFString, &sleepAssertion)
            } else if !on, sleepAssertion != 0 {
                IOPMAssertionRelease(sleepAssertion)
                sleepAssertion = 0
            }
        }
    }
}
