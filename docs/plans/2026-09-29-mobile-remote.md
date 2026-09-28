# ClaudeRemote Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An iPhone app plus a bridge inside ClaudeWatch.app that shows every account and chat on the Mac and lets you reply, stop, approve prompts, start chats, control retries and move chats from the phone.

**Architecture:** Wire types live in a new platform-neutral `WatchProtocol` library shared by the Mac and iOS. A new `WatchBridge` library hosts a small HTTP/1.1 + WebSocket server (Network.framework, hand-rolled framing) bound to Tailscale addresses, with token auth from QR pairing. ClaudeWatch.app adapts `Monitor` to the bridge's `BridgeHandler` protocol. New WatchCore pieces read chat messages (`ChatFeed`), detect pending prompts (`PromptDetector`), run headless replies (`HeadlessRunner`) and drive the desktop window (`DesktopActions`). The iOS app is SwiftUI with one `@Observable` store.

**Tech Stack:** Swift 6.3 toolchain (language mode 5), SwiftPM, Network.framework, CryptoKit, Security, AppKit/AX (Mac); SwiftUI, Swift Charts, AVFoundation (QR), LocalAuthentication, UserNotifications (iOS 18).

**Note on code in this plan:** interfaces, file paths, test cases and commands are pinned here; full bodies live in the commits (each task is small enough to write directly from its interface and tests).

---

## M0 findings (from the Claude desktop app bundle)

- Pending prompts are an in-memory list per session, `{requestId, sessionId, toolName, input, suggestions?, description?, cliToolUseId?}`. They are **not** reliably on disk (the record only has the key while it is being serialised). → Detect prompts from the transcript + process tree instead (`PromptDetector`), and still read `pendingToolPermissions` from the record when present.
- The desktop's own "buddy" device path approves prompts through an internal renderer IPC — not reachable from outside. → Answer desktop prompts through AX (press the matching button), verify by the transcript getting a `tool_result`.
- Deep links: `claude://code/new?folder=<abs path>&q=<prompt>` opens a new Code session in that folder with the prompt filled in (prompt capped at 14 336 chars); `claude://code/continue?session=<local id>`; `claude://code/needs-input`. → New chat = GURL `code/new` to the profile's pid, then press Return in the composer.

## File structure

```
Package.swift                                   + WatchProtocol, WatchBridge libraries; test targets
Sources/WatchProtocol/Models.swift              moved from WatchCore (unchanged types) + prompts on Snapshot
Sources/WatchProtocol/Wire.swift                ChatMessage, PendingPrompt, Job, command bodies, WS messages, pairing, WireCoder
Sources/WatchCore/Exports.swift                 @_exported import WatchProtocol
Sources/WatchCore/ChatFeed.swift                transcript → [ChatMessage], incremental + paging
Sources/WatchCore/PromptDetector.swift          unanswered tool_use + live runner + no new child → PendingPrompt
Sources/WatchCore/ProcessTree.swift             children of a pid with start times (sysctl)
Sources/WatchCore/HeadlessRunner.swift          claude --resume -p, stop, prompt tool wiring
Sources/WatchCore/PromptTool.swift              stdio MCP server for --permission-prompt-tool
Sources/WatchCore/DesktopActions.swift          answer prompt / stop / new chat via AX + deep links; UILock
Sources/WatchCore/Monitor.swift                 + prompts in snapshot, .waiting activity, live runner map
Sources/WatchBridge/HTTP.swift                  request parser, response writer
Sources/WatchBridge/WebSocket.swift             handshake + frame codec
Sources/WatchBridge/Auth.swift                  DeviceStore, PairingGate, PeerFilter, TailscaleAddresses
Sources/WatchBridge/Jobs.swift                  JobBook (idempotency, results), AuditLog
Sources/WatchBridge/PromptBroker.swift          unix socket for headless prompt tool calls
Sources/WatchBridge/Server.swift                listeners, routing, WS hub, BridgeHandler protocol
Sources/WatchBridge/Pusher.swift                APNs JWT + send
Sources/ClaudeWatch/BridgeController.swift      Monitor ↔ BridgeHandler adapter, push events, keep-awake
Sources/ClaudeWatch/PairingWindow.swift         QR + devices list
Sources/ClaudeWatch/App.swift                   start the controller, menu entries (small edits)
Sources/claude-watch/main.swift                 + prompt-tool, set-apns-key, probe-prompt, devices
Tests/WatchProtocolTests/                        round trip + golden JSON
Tests/WatchCoreTests/ChatFeedTests.swift, PromptDetectorTests.swift, HeadlessRunnerTests.swift (+ fixtures)
Tests/WatchBridgeTests/                          HTTP, WebSocket, Auth, Jobs, Server (live on 127.0.0.1), Pusher JWT
iOS/ClaudeRemote.xcodeproj                        app target, synchronized folder, local package ref
iOS/ClaudeRemote/                                 App, Store, Client, Keychain, Views/, Notifications, Info.plist, entitlements
```

---

### Task 1: WatchProtocol target

**Files:** Create `Sources/WatchProtocol/{Models,Wire}.swift`, `Sources/WatchCore/Exports.swift`, `Tests/WatchProtocolTests/WireTests.swift`; move `Sources/WatchCore/Models.swift`; modify `Package.swift`.

- [ ] `git mv Sources/WatchCore/Models.swift Sources/WatchProtocol/Models.swift`; add `public var prompts: [PendingPrompt] = []` to `Snapshot` (decoded with default when missing).
- [ ] Package: `.library(name: "WatchProtocol")` target with platforms macOS 14 / iOS 18; `WatchCore` depends on it; `Exports.swift` = `@_exported import WatchProtocol`.
- [ ] `Wire.swift`: `WireCoder` (secondsSince1970, sortedKeys for encoder), `ChatMessage`, `PendingPrompt`, `Job`, `JobStatus`, `ReplyBody`, `PromptAnswerBody`, `NewChatBody`, `ModeBody`, `MoveBody`, `DeviceRegistration`, `PairRequest`, `PairResponse`, `PairingPayload` (QR content), `MessagesPage`, `FolderSuggestion`, `WSClientMessage`, `WSServerMessage` (enum with `type` discriminator), `BridgeStatus` (warnings, mac name).
- [ ] Tests: encode→decode equality for each; golden JSON for `WSServerMessage.snapshot` (fixture string) decodes; `Snapshot` without `prompts` key decodes.
- [ ] `swift build && swift test` — all pass. Commit.

### Task 2: ChatFeed

**Files:** Create `Sources/WatchCore/ChatFeed.swift`, `Tests/WatchCoreTests/ChatFeedTests.swift`, `Tests/WatchCoreTests/Fixtures/chat.jsonl`.

Interface:
```swift
public final class ChatFeed {
    public init(url: URL)
    /// New messages since the last call (first call: everything). Holds back a partial last line.
    public func poll() -> [ChatMessage]
    public static func messages(fromLines: [Data]) -> [ChatMessage]
    public static func page(url: URL, before: Int?, limit: Int) -> MessagesPage   // cursor = message index
    public static func oneLiner(tool: String, input: [String: Any]) -> String
}
```
- [ ] Fixture: user prompt, assistant text + tool_use (Bash, Edit), tool_result ok, tool_result is_error, sidechain entry (ignored), isMeta user (ignored), rate-limit api error, final assistant text.
- [ ] Tests: expected kinds/texts in order; Bash one-liner "Ran swift build"; Edit → "Edited App.swift"; tool ✓/✗ from paired result; partial trailing line not emitted until completed; second poll after append yields only new; page(before:limit:) returns the last N and a cursor.
- [ ] Implement; run `swift test --filter ChatFeedTests`; commit.

### Task 3: ProcessTree + PromptDetector

**Files:** Create `Sources/WatchCore/{ProcessTree,PromptDetector}.swift`, `Tests/WatchCoreTests/PromptDetectorTests.swift`.

```swift
public enum ProcessTree { public static func children(of pid: Int32) -> [(pid: Int32, startedAt: Date)] }
public struct OpenToolUse: Sendable { public var id, name: String; public var input: [String: String]; public var at: Date }
public enum PromptDetector {
    /// The last assistant tool_use without a tool_result in the main transcript (nil if none).
    public static func openToolUse(url: URL) -> OpenToolUse?        // reads the last 256 KB
    /// Decide whether an open tool use is waiting on the user.
    public static func isWaiting(_ t: OpenToolUse, transcriptMtime: Date, childStarts: [Date], now: Date) -> Bool
    public static func prompt(for s: SessionInfo, tool: OpenToolUse) -> PendingPrompt
}
```
Rules: quiet ≥ 4 s since mtime; no child process started after `t.at - 1 s`; thresholds by tool: `Agent`/`Task` never; `WebFetch`/`WebSearch` 25 s; `mcp__*` 20 s; `AskUserQuestion`/`ExitPlanMode` → waiting at once (kind `.question`); everything else 4 s.
- [ ] Tests: each rule (bash with child → not waiting; bash no child after 5 s → waiting; Edit at 2 s → not; Agent at 10 min → not; AskUserQuestion → waiting); `openToolUse` on a fixture ending in unanswered Bash returns it, on one ending in tool_result returns nil.
- [ ] Implement; test; commit.

### Task 4: Monitor integration

**Files:** Modify `Sources/WatchCore/Monitor.swift`, `Sources/WatchCore/Readers.swift`.
- [ ] `SessionIndex.parse` also maps `pendingToolPermissions` items into `SessionInfo.pendingPrompts: [PendingPrompt]` (source `.desktop`, id = `requestId`).
- [ ] In `poll()`: for each non-archived session with a live runner, detect via `PromptDetector` (record prompts take precedence); a session with a prompt gets activity `.waiting`; `Snapshot.prompts` = all; `public private(set) var liveRunners: [String: Int32]`.
- [ ] `swift test` stays green; `swift run claude-watch status --json | head` still works. Commit.

### Task 5: HTTP codec

**Files:** Create `Sources/WatchBridge/HTTP.swift`, `Tests/WatchBridgeTests/HTTPTests.swift`; Package gets `WatchBridge` (deps WatchProtocol) + `WatchBridgeTests`.
```swift
public struct HTTPRequest { method, path, query: [String:String], headers: [String:String] (lowercased), body: Data }
public enum HTTPParser { public static func parse(_ buf: Data) -> (HTTPRequest, consumed: Int)? ; throws on > 1 MB }
public struct HTTPResponse { status: Int; headers; body; static func json<T: Encodable>(_:status:); func serialize() -> Data }
```
- [ ] Tests: GET with query; POST with Content-Length body split across two buffers (nil until complete); header case-insensitivity; oversize → error; response serialisation line format.
- [ ] Implement; test; commit.

### Task 6: WebSocket codec

**Files:** Create `Sources/WatchBridge/WebSocket.swift`, `Tests/WatchBridgeTests/WebSocketTests.swift`.
```swift
public enum WebSocket {
    public static func acceptKey(for key: String) -> String       // SHA1 + GUID, base64
    public enum Opcode: UInt8 { case cont = 0, text = 1, binary = 2, close = 8, ping = 9, pong = 10 }
    public static func encode(_ op: Opcode, _ payload: Data) -> Data   // server frames: unmasked
    public static func decode(_ buf: Data) throws -> (op: Opcode, payload: Data, consumed: Int)?   // client frames must be masked
}
```
- [ ] Tests: RFC 6455 sample key `dGhlIHNhbXBsZSBub25jZQ==` → `s3pPLMBiTxaQ9kYGzzhZRbK+xOo=`; masked "Hello" decodes; 126 and 127 length forms; unmasked client frame rejected; partial frame → nil.
- [ ] Implement; test; commit.

### Task 7: Auth

**Files:** Create `Sources/WatchBridge/Auth.swift`, `Tests/WatchBridgeTests/AuthTests.swift`.
```swift
public struct Device: Codable { id, name, tokenHash, createdAt, lastSeenAt, apnsToken?, apnsEnvironment?, notify: [String: Bool] }
public final class DeviceStore { init(url:); func add(name:) -> (Device, token: String); func authenticate(_ bearer: String) -> Device?; func update(_:); func remove(id:); var all }
public final class PairingGate { func open(now:) -> String (6-digit); func close(); func redeem(_ code: String, now:) -> Bool  // 2 min, single use, 5 failures close }
public enum PeerFilter { static func allowed(_ host: String) -> Bool }   // 127.0.0.1, ::1, 100.64.0.0/10, fd7a:115c:a1e0::/48
public enum TailscaleAddresses { static func current() -> [String] }     // getifaddrs filtered by PeerFilter ranges
```
- [ ] Tests: token round trip authenticates, wrong token nil, stored file contains no raw token; gate expiry, single use, lockout after 5; filter cases (100.64.0.1 yes, 100.128.0.1 no, 192.168.1.2 no, fd7a:115c:a1e0::1 yes).
- [ ] Implement; test; commit.

### Task 8: Jobs + audit

**Files:** Create `Sources/WatchBridge/Jobs.swift`, `Tests/WatchBridgeTests/JobsTests.swift`.
```swift
public final class JobBook { func start(requestId: String, command: String, deviceId: String) -> (Job, isNew: Bool); func finish(_ id: String, _ status: JobStatus, reason: String?) -> Job?; var onChange: ((Job, deviceId) -> Void)? }   // remembers 500
public final class AuditLog { init(url:); func append(device:, command:, target:, result:) }
```
- [ ] Tests: same requestId returns the same job with isNew false; finish updates and fires onChange; capacity eviction; audit appends JSON lines.
- [ ] Implement; test; commit.

### Task 9: Server

**Files:** Create `Sources/WatchBridge/Server.swift`, `Tests/WatchBridgeTests/ServerTests.swift`.
```swift
public protocol BridgeHandler: AnyObject {
    func snapshot() -> Snapshot?
    func status() -> BridgeStatus
    func messages(chatId: String, before: Int?, limit: Int) -> MessagesPage?
    func chatFeedURL(chatId: String) -> URL?
    func folders(profileId: String) -> [FolderSuggestion]
    func usage(profileId: String) -> [UsageSample]
    func perform(_ command: BridgeCommand, device: Device, done: @escaping (JobStatus, String?) -> Void)
}
public enum BridgeCommand { reply(chatId, text), prompt(chatId, PromptAnswerBody), stop(chatId), newChat(NewChatBody), retry(itemId), cancelRetry(itemId), mode(profileId, RetryMode), move(MoveBody), undoMove(id), cancelMove(id), restartMoves }
public final class BridgeServer {
    public init(port: UInt16, devices: DeviceStore, handler: BridgeHandler, hosts: () -> [String])
    public let pairing: PairingGate
    public func start() throws; public func stop()
    public func publish(snapshot: Snapshot)            // pushes to every WS client when changed
    public func revoke(deviceId: String)               // closes its sockets
    public var onDeviceRegistered: ((Device) -> Void)?
}
```
Routes per the spec (`/pair`, `/v1/snapshot`, `/v1/status`, `/v1/chats/{id}/messages`, `/v1/folders`, `/v1/accounts/{id}/usage`, command POSTs, `/v1/devices`, `DELETE /v1/devices/self`, `/v1/stream`). Subscribed chats are tailed with a 1 s timer through `ChatFeed`.
- [ ] Tests (real listener on 127.0.0.1, random port, fake handler, URLSession client): 401 without token; pairing flow gives a working token; `/v1/snapshot` JSON decodes; POST reply → 202 + jobId, repeated requestId same jobId; WS: connect with token → first message is snapshot; subscribe to a temp transcript → append a line → receive `messages`; `revoke` closes the socket.
- [ ] Implement; test; commit.

### Task 10: HeadlessRunner + prompt tool + broker

**Files:** Create `Sources/WatchCore/{HeadlessRunner,PromptTool}.swift`, `Sources/WatchBridge/PromptBroker.swift`, `Tests/WatchCoreTests/HeadlessRunnerTests.swift`; modify `Sources/claude-watch/main.swift` (`prompt-tool`).
```swift
public final class HeadlessRunner {
    public init(binary: (Profile) -> String? = CLIRetry.binary, token: (String) -> String? = TokenStore.get, promptToolCommand: [String]?)
    public func reply(_ text: String, session: SessionInfo, profile: Profile, activity: SessionStatus.Activity) -> Result<Int32, RetryError>
    public func stop(sessionId: String) -> Bool
    public func isRunning(sessionId: String) -> Bool
    public var onExit: ((String, Int32) -> Void)?
}
public enum PromptTool { public static func serve(socketPath: String, runId: String) }  // JSON-RPC over stdio
public final class PromptBroker { init(path:); start(); var pending: [PendingPrompt]; func answer(id:, decision:) -> Bool; var onChange }
```
- [ ] Tests with a stub `claude` script (writes its args to a file, sleeps): refuses when activity == .working (`busy`); args contain `--resume <cli> -p <text>` and `--permission-prompt-tool mcp__claudewatch__approve`; `stop` terminates within 6 s; missing token → blocked message.
- [ ] Prompt tool: test the JSON-RPC handler function (`initialize`, `tools/list`, `tools/call` with a fake answer provider) returns `{"behavior":"allow","updatedInput":…}` / deny.
- [ ] Implement; test; commit.

### Task 11: DesktopActions

**Files:** Create `Sources/WatchCore/DesktopActions.swift`; modify `Sources/WatchCore/Executors.swift` (share `UILock`), `Sources/claude-watch/main.swift` (`probe-prompt`).
```swift
public enum UILock { public static func run<T>(_ body: () -> T) -> T }
public enum DesktopActions {
    public static func answer(_ p: PendingPrompt, decision: PromptDecision, session: SessionInfo, profile: Profile, dryRun: Bool = false) -> Result<String, RetryError>
    public static func stop(session: SessionInfo, profile: Profile) -> Result<String, RetryError>
    public static func newChat(profile: Profile, cwd: String, prompt: String) -> Result<String, RetryError>
    static func matchButton(_ titles: [(title: String, y: CGFloat)], for d: PromptDecision) -> Int?   // pure, tested
}
```
- [ ] Unit-test `matchButton` (lowest matching "Allow"/"Allow once" for allow, "Always allow…"/"Don't ask again" for allowAlways, "Deny"/"No"/"Reject" for deny; ignores unrelated buttons).
- [ ] Implement AX paths; `claude-watch probe-prompt <session>` lists visible button titles without pressing. Commit.

### Task 12: Pusher

**Files:** Create `Sources/WatchBridge/Pusher.swift`, `Tests/WatchBridgeTests/PusherTests.swift`; modify `main.swift` (`set-apns-key`).
```swift
public struct APNsKey { keyId, teamId, pem; static func load() -> APNsKey?; func save() }   // Keychain
public final class Pusher { init(key: APNsKey?, topic: String); func jwt(now:) throws -> String; func send(_ n: PushNote, to device: Device) }
public struct PushNote { category, title, body, threadId, collapseId, userInfo: [String: String] }
```
- [ ] Test: JWT header/claims decode and the ES256 signature verifies with the public key of a generated P256 key.
- [ ] Implement; commit.

### Task 13: ClaudeWatch integration

**Files:** Create `Sources/ClaudeWatch/{BridgeController,PairingWindow}.swift`; modify `App.swift`, `Config.swift` (bridge settings), `install.sh` (nothing new needed beyond build).
- [ ] `BridgeController: BridgeHandler` uses `Monitor` (perform / snapshot), `HeadlessRunner`, `DesktopActions`, `PromptBroker`; merges broker prompts into the published snapshot; tracks "touched" chats for the finished-turn push; maps `WatchEvent` → push; keep-awake power assertion.
- [ ] Menu: "Pair iPhone…", "Paired devices", bridge status line + last remote action.
- [ ] Manual check: `./install.sh --no-open` builds; launch; `curl -s 127.0.0.1:7433/v1/snapshot` → 401. Commit.

### Task 14: iOS app — project, client, store, pairing

**Files:** Create `iOS/ClaudeRemote.xcodeproj/project.pbxproj`, `iOS/ClaudeRemote/{ClaudeRemoteApp,RemoteClient,RemoteStore,Keychain,PairingView,QRScanner}.swift`, `Info.plist`, `ClaudeRemote.entitlements`.
- [ ] Project: objectVersion 77, `PBXFileSystemSynchronizedRootGroup` for `ClaudeRemote/`, `XCLocalSwiftPackageReference` "../" product `WatchProtocol`, iOS 18, bundle id `dev.lajward.ClaudeRemote`, ATS exception for `ts.net` + local networking, camera usage string, push entitlement.
- [ ] `xcodebuild -project iOS/ClaudeRemote.xcodeproj -scheme ClaudeRemote -destination 'generic/platform=iOS Simulator' build` succeeds. Commit.

### Task 15: iOS screens

**Files:** `iOS/ClaudeRemote/Views/{RootView,ChatsView,ChatView,MessageRow,PromptCard,NewChatView,AccountsView,AccountDetailView,MacView,Components}.swift`.
- [ ] Per spec §iOS app. Previews from `Fixtures.swift` sample snapshot. Build succeeds. Commit.

### Task 16: iOS notifications + Face ID

**Files:** `iOS/ClaudeRemote/{Notifications,AppLock}.swift`, `AppDelegate` adaptor.
- [ ] Register categories PROMPT (Allow auth-required, Deny, Open), CHAT (Continue, Open), ACCOUNT (Open); register device token with `/v1/devices`; background action → command POST with 20 s wait; Face ID gate on launch/foreground and before Allow Bash / New chat. Build. Commit.

### Task 17: End to end + docs

- [ ] Run the bridge from a debug ClaudeWatch build; pair the Simulator app against `127.0.0.1:7433` (pairing sheet accepts manual host + code); verify snapshot, chat view streaming, reply busy/409 path. Screenshot.
- [ ] README: "iPhone remote" section (setup, pairing, security). Spec: M0 findings + the simplification (full snapshot on change instead of patches). Commit.

## Self-review

- Spec coverage: bridge/auth/pairing (5–9), chat view (2, 9, 15), prompts (3, 4, 10, 11, 15, 16), reply/continue/stop (10, 11), new chat (11, 15), retry/mode/moves (9, 13, 15), usage chart (9, 15), push (12, 13, 16), Face ID (16), keep-awake (13), offline cache (14), tailnet owner check (7/13 via `tailscale whois`, best effort), audit (8). Covered.
- Deviation from spec: `snapshotPatch` replaced by sending the full snapshot when it changed (tens of KB every ≥15 s over the tailnet; simpler and cannot drift). Spec updated in Task 17.
