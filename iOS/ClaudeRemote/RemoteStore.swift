import Foundation
import Observation
import WatchProtocol

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var isError: Bool
}

enum DeepLink: Equatable {
    case chat(String)
    case account(String)
}

/// Everything the screens show, fed by one WebSocket plus a few REST calls. Commands go through here so
/// their pending state and failures surface in one place.
@Observable @MainActor
final class RemoteStore {
    enum Connection: Equatable {
        case connecting, connected, reconnecting, offline
    }

    private(set) var credentials: Credentials?
    private(set) var snapshot: Snapshot?
    /// When the snapshot on screen arrived (from the Mac, or from the disk cache).
    private(set) var lastUpdated: Date?
    private(set) var connection: Connection = .offline {
        didSet { live.reachable(connection == .connected) }   // the Live Activity shows when the Mac is lost
    }
    private(set) var bridgeStatus: BridgeStatus?
    private(set) var lastError: String?

    // The chat on screen.
    private(set) var openChatId: String?
    private(set) var messages: [ChatMessage] = []
    private(set) var olderCursor: Int?
    private(set) var loadingOlder = false
    private(set) var messagesLoaded = false
    /// The transcript on screen came from the disk cache and the Mac's copy hasn't arrived yet.
    private(set) var messagesStale = false
    @ObservationIgnored private var cacheSave: Task<Void, Never>?
    @ObservationIgnored private var prefetching = false

    private(set) var jobs: [String: Job] = [:]
    /// The Mac's resources while a view watches them (`watchSystem`), with up to 30 minutes of history.
    private(set) var system: SystemHealth?
    @ObservationIgnored private var watchingSystem = false
    private var pending: [String: RemoteCommand] = [:]    // by requestId
    var toast: Toast?
    var deepLink: DeepLink?

    /// The Lock Screen Live Activity and the widgets.
    let live = LiveActivities()

    @ObservationIgnored private var client: RemoteClient?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var socket: StreamSocket?
    @ObservationIgnored private var failures = 0
    /// The wait between reconnect attempts; cancelled to retry at once.
    @ObservationIgnored private var backoff: Task<Void, Never>?
    @ObservationIgnored private var lastMessageAt = Date()
    @ObservationIgnored private var messageIndex: [String: Int] = [:]
    @ObservationIgnored private var lastCacheWrite = Date.distantPast
    @ObservationIgnored private var isPreview = false

    init() {
        credentials = Keychain.load()
        if let credentials { client = RemoteClient(credentials: credentials) }
        if credentials != nil, let cached = SnapshotCache.load() {
            snapshot = cached.snapshot
            lastUpdated = cached.receivedAt
        }
        // "try demo" was chosen last time and nothing has been paired since.
        if credentials == nil, UserDefaults.standard.bool(forKey: Self.demoModeKey) { enterDemo() }
        live.register = { [weak self] r in await self?.register(r) ?? false }
        if let credentials { live.paired(credentials) }
        live.start()
    }

    /// For previews: a store that never touches the network, Keychain or disk.
    init(preview snapshot: Snapshot?, connection: Connection = .connected, messages: [ChatMessage] = [],
         paired: Bool = false) {
        self.snapshot = snapshot
        self.lastUpdated = snapshot?.at
        self.connection = connection
        self.messages = messages
        self.messagesLoaded = true
        self.isPreview = true
        if snapshot != nil || paired {
            credentials = Credentials(baseURLs: [URL(string: "http://127.0.0.1:7433")!], token: "preview",
                                      deviceId: "dev-preview", macName: "Rashid's MacBook Pro")
        }
        bridgeStatus = BridgeStatus(macName: "Rashid's MacBook Pro", version: "1.4.0",
                                    warnings: ["Accessibility permission missing — prompts can't be answered"],
                                    pushConfigured: true, deviceId: "dev-preview",
                                    notify: ["prompt": true, "finished": true, "failed": true, "account": false])
    }

    // MARK: Demo

    static let demoModeKey = "demoMode"

    /// The in-app demo ("try demo" on the pairing screen, for App Review and the curious): the sample data
    /// from `-demo`, commands simulated, nothing sent anywhere. Kept across launches until a real pairing.
    private(set) var isDemo = false

    func enterDemo() {
        stop()
        streamTask?.cancel()
        streamTask = nil
        client = nil
        isPreview = true
        isDemo = true
        snapshot = Fixtures.snapshot
        lastUpdated = Date()
        connection = .connected
        messages = Fixtures.messages
        messagesLoaded = true
        system = Fixtures.system
        snapshot?.systemLevel = Fixtures.system.level
        olderCursor = nil
        pending = [:]
        jobs = [:]
        credentials = Credentials(baseURLs: [URL(string: "http://demo-mac.local:7433")!], token: "demo",
                                  deviceId: "demo-iphone", macName: "Demo MacBook Pro")
        bridgeStatus = BridgeStatus(macName: "Demo MacBook Pro", version: "demo", warnings: [],
                                    pushConfigured: true, deviceId: "demo-iphone",
                                    notify: ["prompt": true, "finished": true, "failed": true, "account": false])
        UserDefaults.standard.set(true, forKey: Self.demoModeKey)
    }

    /// Back to the pairing screen.
    func exitDemo() {
        UserDefaults.standard.removeObject(forKey: Self.demoModeKey)
        isDemo = false
        isPreview = false
        credentials = nil
        snapshot = nil
        bridgeStatus = nil
        lastUpdated = nil
        messages = []
        openChatId = nil
        system = nil
        pending = [:]
        jobs = [:]
        toast = nil
        connection = .offline
    }

    var isPaired: Bool { credentials != nil }
    var canSend: Bool { connection == .connected }
    var prompts: [PendingPrompt] { snapshot?.prompts ?? [] }

    func isPending(_ key: String) -> Bool { pending.values.contains { $0.key == key } }
    func isPending(prefix: String) -> Bool { pending.values.contains { $0.key.hasPrefix(prefix) } }

    // MARK: Lifecycle

    func start() {
        guard client != nil, streamTask == nil else { return }
        failures = 0
        if connection != .connected { connection = .connecting }
        streamTask = Task { [weak self] in await self?.runStream() }
    }

    func stop() {
        if isPreview { return }
        streamTask?.cancel()
        streamTask = nil
        socket?.close()
        socket = nil
        RelayProxy.shared.reset()
        if connection == .connected { connection = .reconnecting }
    }

    /// Retry now instead of waiting out the backoff (pull to refresh, the retry buttons). An attempt
    /// already under way is left to finish, so pulling or scrolling repeatedly doesn't restart it.
    func reconnect() {
        guard client != nil else { return }
        guard streamTask != nil else { return start() }
        backoff?.cancel()
    }

    /// Drops the connection and opens a new one (changing how to reach the Mac).
    func restart() {
        stop()
        start()
    }

    /// Which way the stream reaches the Mac right now (shown on the Mac tab).
    private(set) var activePath: RemoteClient.Path?

    /// Switches between auto / direct / relay and reconnects that way.
    func setConnectVia(_ via: ConnectVia) async {
        guard let client else { return }
        var c = await client.credentials   // keeps what the client learned (host order, relay preference)
        c.via = via == .preferred ? nil : via
        Keychain.save(c)
        credentials = c
        self.client = RemoteClient(credentials: c)
        activePath = nil
        restart()
    }

    func didPair(_ c: Credentials) {
        // A real pairing ends any demo for good.
        UserDefaults.standard.removeObject(forKey: Self.demoModeKey)
        isDemo = false
        isPreview = false
        messages = []
        openChatId = nil
        pending = [:]
        jobs = [:]
        Keychain.save(c)
        credentials = c
        client = RemoteClient(credentials: c)
        snapshot = nil
        lastUpdated = nil
        start()
        live.paired(c)
        Task { await registerPushIfNeeded() }
    }

    /// Unpairs on the Mac, then forgets the pairing here. With `force`, forgets even if the Mac can't be reached.
    func unpair(force: Bool = false) async -> Bool {
        if let client {
            do { try await client.unpair() } catch RemoteError.unauthorized {
                // Already gone on the Mac.
            } catch {
                if !force { toast = Toast(message: error.localizedDescription, isError: true); return false }
            }
        }
        forgetPairing()
        return true
    }

    private func forgetPairing() {
        stop()
        Keychain.delete()
        SnapshotCache.clear()
        MessageCache.clear()
        LocalDrafts.clear()
        UserDefaults.standard.removeObject(forKey: Self.registeredTokenKey)
        live.paired(nil)
        credentials = nil
        client = nil
        snapshot = nil
        bridgeStatus = nil
        lastUpdated = nil
        messages = []
        openChatId = nil
        pending = [:]
        jobs = [:]
        connection = .offline
    }

    private func lostPairing() {
        forgetPairing()
        toast = Toast(message: "Your Mac no longer recognises this iPhone. Pair again.", isError: true)
    }

    // MARK: Stream

    private func runStream() async {
        var delay: Double = 1
        while !Task.isCancelled, let client {
            do {
                let s = try await client.openStream()
                socket = s
                lastMessageAt = Date()
                let pinger = Task { [weak self] in await self?.keepAlive(s) }
                defer { pinger.cancel() }
                try await s.send(WSClientMessage(type: .ping))   // a quick pong proves the socket is up
                var first = true
                while !Task.isCancelled {
                    let m = try await s.receive()
                    lastMessageAt = Date()
                    if first {
                        first = false
                        delay = 1
                        didConnect(s)
                    }
                    handle(m)
                }
            } catch RemoteError.unauthorized {
                lostPairing()
                return
            } catch {
                lastError = error.localizedDescription
            }
            socket?.close()
            socket = nil
            if Task.isCancelled { return }
            failures += 1
            connection = failures < 3 ? .reconnecting : .offline
            await client.forgetBase()
            RelayProxy.shared.reset()
            let wait = Task { _ = try? await Task.sleep(for: .seconds(delay)) }
            backoff = wait
            await wait.value
            backoff = nil
            delay = min(delay * 2, 30)
        }
    }

    /// Pings every 15 s; a connection silent for 45 s is dropped so the loop reconnects.
    private func keepAlive(_ s: StreamSocket) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(15))
            if Task.isCancelled { return }
            if Date().timeIntervalSince(lastMessageAt) > 45 { s.close(); return }
            try? await s.send(WSClientMessage(type: .ping))
        }
    }

    private func didConnect(_ s: StreamSocket) {
        connection = .connected
        failures = 0
        lastError = nil
        if let client { Task { activePath = await client.path } }
        if let id = openChatId {
            Task { try? await s.send(WSClientMessage(type: .subscribe, chatId: id)) }
        }
        if watchingSystem {
            Task { try? await s.send(WSClientMessage(type: .watchSystem)) }
        }
        Task {
            await refreshStatus()
            await registerPushIfNeeded()
            await prefetchRecent()
        }
    }

    private func handle(_ m: WSServerMessage) {
        switch m {
        case .snapshot(let s):
            snapshot = s
            lastUpdated = Date()
            live.update(s, macName: credentials?.macName ?? "Mac")
            if Date().timeIntervalSince(lastCacheWrite) > 5 {
                lastCacheWrite = Date()
                let at = lastUpdated ?? Date()
                Task.detached(priority: .utility) { SnapshotCache.save(s, receivedAt: at) }
            }
        case .messages(let chatId, let msgs, let reset, let before):
            guard chatId == openChatId else { return }
            if reset {
                messages = msgs
                olderCursor = before
                rebuildIndex()
                messagesStale = false
            } else {
                upsert(msgs)
            }
            messagesLoaded = true
            saveOpenChat(after: reset ? 0 : 2)
        case .job(let j):
            record(j)
        case .system(let h):
            // The first reading after watching carries the full history; later ones add their newest point.
            if h.history.count > 1 || system == nil {
                system = h
            } else {
                var n = h
                n.history = Array(((system?.history ?? []) + h.history).suffix(360))
                system = n
            }
        case .pong:
            break
        }
    }

    // MARK: System health

    func watchSystem() {
        watchingSystem = true
        if isPreview { return }
        if let socket, connection == .connected {
            Task { try? await socket.send(WSClientMessage(type: .watchSystem)) }
        }
    }

    func unwatchSystem() {
        watchingSystem = false
        if isPreview { return }
        if let socket, connection == .connected {
            Task { try? await socket.send(WSClientMessage(type: .unwatchSystem)) }
        }
    }

    // MARK: Open chat

    func open(chat id: String) {
        guard openChatId != id else { return }
        openChatId = id
        if isPreview { return }
        cacheSave?.cancel()
        if let cached = MessageCache.load(id) {
            messages = cached.messages
            olderCursor = cached.before
            messagesLoaded = true
            messagesStale = true
        } else {
            messages = []
            olderCursor = nil
            messagesLoaded = false
            messagesStale = false
        }
        rebuildIndex()
        if let socket, connection == .connected {
            Task { try? await socket.send(WSClientMessage(type: .subscribe, chatId: id)) }
        }
    }

    func close(chat id: String) {
        guard openChatId == id else { return }
        if !isPreview, !isDemo, !messagesStale { saveOpenChat(after: 0) }
        openChatId = nil
        if let socket, connection == .connected {
            Task { try? await socket.send(WSClientMessage(type: .unsubscribe, chatId: id)) }
        }
    }

    func loadOlder() async {
        guard let id = openChatId, let cursor = olderCursor, !loadingOlder, let client else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        do {
            let page = try await client.messages(chatId: id, before: cursor, limit: 50)
            guard id == openChatId else { return }
            let fresh = page.messages.filter { messageIndex[$0.id] == nil }
            messages.insert(contentsOf: fresh, at: 0)
            olderCursor = page.before
            rebuildIndex()
        } catch {
            show(error)
        }
    }

    /// Writes the open chat's transcript to the disk cache, `after` seconds from now (coalesced).
    private func saveOpenChat(after seconds: Double) {
        guard let id = openChatId, !isPreview, !isDemo else { return }
        let msgs = messages, cursor = olderCursor
        cacheSave?.cancel()
        cacheSave = Task.detached(priority: .utility) {
            if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
            guard !Task.isCancelled else { return }
            MessageCache.save(id, messages: msgs, before: cursor)
        }
    }

    /// Fetches the latest messages of the chats most likely to be opened next, so they open from cache.
    private func prefetchRecent() async {
        guard !prefetching, !isPreview, !isDemo, let snap = snapshot else { return }
        prefetching = true
        defer { prefetching = false }
        let recent = snap.sessions.sorted { $0.info.lastActivityAt > $1.info.lastActivityAt }.prefix(6)
        for s in recent where s.id != openChatId {
            guard let client, connection == .connected else { return }
            let cachedAt = await Task.detached(priority: .utility) { MessageCache.load(s.id)?.savedAt }.value
            if let cachedAt, cachedAt >= s.info.lastActivityAt { continue }
            guard let page = try? await client.messages(chatId: s.id, before: nil, limit: 200) else { continue }
            let id = s.id
            await Task.detached(priority: .utility) { MessageCache.save(id, messages: page.messages, before: page.before) }.value
        }
    }

    private func upsert(_ msgs: [ChatMessage]) {
        for m in msgs {
            if let i = messageIndex[m.id], i < messages.count, messages[i].id == m.id {
                messages[i] = m
            } else {
                messageIndex[m.id] = messages.count
                messages.append(m)
            }
        }
    }

    private func rebuildIndex() {
        messageIndex = Dictionary(messages.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { _, b in b })
    }

    // MARK: Drafts

    /// Tells the Mac what's in a chat's composer, so it shows there. Best effort: false when it didn't arrive.
    func postDraft(chatId: String, text: String) async -> Bool {
        guard !isPreview, !isDemo, let client, canSend else { return false }
        return (try? await client.setDraft(chatId: chatId, text: text)) != nil
    }

    // MARK: Commands

    /// Sends a command and waits for its final job. Nothing is queued while offline.
    @discardableResult
    func perform(_ c: RemoteCommand) async -> Job? {
        if isPreview { return await simulate(c) }
        guard let client, canSend else {
            toast = Toast(message: "Your Mac is offline — nothing was sent.", isError: true)
            return nil
        }
        pending[c.requestId] = c
        defer { pending[c.requestId] = nil }
        do {
            let job = try await client.perform(c)
            record(job)
            let final = await waitForFinal(job, c)
            if final.status == .failed || final.status == .blocked {
                toast = Toast(message: final.reason ?? "\(c.label) failed.", isError: true)
            }
            return final
        } catch RemoteError.unauthorized {
            lostPairing()
            return nil
        } catch {
            show(error)
            return nil
        }
    }

    /// Demo mode: pretend the Mac did it after a moment.
    private func simulate(_ c: RemoteCommand) async -> Job {
        pending[c.requestId] = c
        try? await Task.sleep(for: .seconds(1))
        pending[c.requestId] = nil
        // An answered prompt goes away, as it would once the Mac passed the answer on.
        if c.key.hasPrefix("prompt:") {
            let id = String(c.key.dropFirst("prompt:".count))
            snapshot?.prompts.removeAll { $0.id == id }
        }
        if isDemo { toast = Toast(message: "demo · \(c.label.lowercased()) simulated, nothing was sent", isError: false) }
        return Job(id: "demo-" + c.requestId, requestId: c.requestId, command: c.label, target: nil, status: .done, at: Date())
    }

    /// Final status arrives over the WebSocket; the command is also resent now and then (same requestId,
    /// so the bridge just reports the job) in case that event was lost in a reconnect.
    private func waitForFinal(_ start: Job, _ c: RemoteCommand) async -> Job {
        var job = start
        var waited: Double = 0, sinceResend: Double = 0
        while !job.status.isFinal && waited < 600 {
            try? await Task.sleep(for: .milliseconds(250))
            waited += 0.25; sinceResend += 0.25
            if let j = jobs[job.id] { job = j }
            if !job.status.isFinal, canSend, sinceResend >= (waited < 30 ? 5 : 15), let client {
                sinceResend = 0
                if let j = try? await client.perform(c) { record(j); job = j }
            }
        }
        return job
    }

    private func record(_ j: Job) {
        if let old = jobs[j.id], old.status.isFinal, !j.status.isFinal { return }
        jobs[j.id] = j
        if jobs.count > 200 {
            for old in jobs.values.sorted(by: { $0.at < $1.at }).prefix(jobs.count - 150) { jobs[old.id] = nil }
        }
    }

    func show(_ error: Error) {
        toast = Toast(message: error.localizedDescription, isError: true)
    }

    // MARK: Reads

    func folders(profileId: String) async -> [FolderSuggestion] {
        if isPreview { return Fixtures.folders }
        return (try? await client?.folders(profileId: profileId)) ?? []
    }

    func usage(profileId: String) async throws -> [UsageSample] {
        if isPreview { return Fixtures.usage }
        guard let client else { return [] }
        return try await client.usage(profileId: profileId)
    }

    func refreshStatus() async {
        guard let client else { return }
        guard let s = try? await client.status() else { return }
        bridgeStatus = s
        if let r = s.relay { await adoptRelay(r) }
    }

    /// A phone paired before the relay existed learns its room and key from the Mac, so it no longer needs Tailscale.
    private func adoptRelay(_ r: RelayInfo) async {
        guard !isPreview, !isDemo, let client else { return }
        var c = await client.credentials
        guard c.relay != r else { return }
        c.relay = r
        Keychain.save(c)
        credentials = c
        self.client = RemoteClient(credentials: c)
    }

    // MARK: Device settings

    func setNotify(_ event: NotifyEvent, on: Bool) async {
        if isPreview { bridgeStatus?.notify[event.rawValue] = on; return }
        guard let client else { return }
        do { bridgeStatus = try await client.register(DeviceRegistration(notify: [event.rawValue: on])) } catch { show(error) }
    }

    static let apnsTokenKey = "apnsToken"
    private static let registeredTokenKey = "apnsRegistered"

    func didReceivePushToken(_ hex: String) {
        UserDefaults.standard.set(hex, forKey: Self.apnsTokenKey)
        Task { await registerPushIfNeeded() }
    }

    /// Sends a device registration (Live Activity tokens and the like) to the Mac.
    func register(_ r: DeviceRegistration) async -> Bool {
        guard let client, !isDemo, let s = try? await client.register(r) else { return false }
        bridgeStatus = s
        return true
    }

    /// Sends the APNs token to the Mac once per pairing (and again if it changes).
    private func registerPushIfNeeded() async {
        guard let client, let credentials, let token = UserDefaults.standard.string(forKey: Self.apnsTokenKey) else { return }
        let marker = credentials.deviceId + ":" + token
        guard UserDefaults.standard.string(forKey: Self.registeredTokenKey) != marker else { return }
        #if DEBUG
        let env = "sandbox"
        #else
        let env = "production"
        #endif
        if let s = try? await client.register(DeviceRegistration(apnsToken: token, environment: env)) {
            bridgeStatus = s
            UserDefaults.standard.set(marker, forKey: Self.registeredTokenKey)
        }
    }
}
