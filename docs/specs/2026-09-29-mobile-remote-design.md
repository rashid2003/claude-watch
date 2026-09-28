# ClaudeRemote — iPhone remote for claude-watch — design

An iPhone app that connects to ClaudeWatch on the Mac and shows every Claude
account and chat in one place: live status, usage and forecasts, the full
conversation of any chat, and pending permission prompts. From the phone you can
reply / continue, stop, answer prompts, start a new chat, control the retry
queue and move chats. Alerts that need you arrive as push notifications with
Allow / Deny actions. Builds on `2026-09-29-claude-watch-design.md` and
`2026-09-29-move-chat-design.md`.

## Decisions

| Question | Decision |
|---|---|
| Platform | Native iPhone app, SwiftUI, iOS 18+. No Android. |
| Reach | Anywhere, over Tailscale (already installed on the Mac). No server of ours, no open ports. |
| Push | Paid Apple Developer account. The Mac sends to APNs directly (token auth, `.p8`). |
| Where phone-driven chats run | Hybrid. Reply / continue run headless (`claude --resume -p`). Prompts raised by the desktop app are answered in the desktop window (AX). New chats open in the account's desktop window. |
| Chat view | Full conversation: prompts, markdown replies, tool calls collapsed to one line, live streaming, task list. |
| v1 extras | Retry queue control, usage & forecasts, move chat, stop / interrupt. |
| Mac side | Bridge inside `ClaudeWatch.app` (it already owns `Monitor` and the Accessibility / Automation grants). Not a separate daemon. |

Rejected: a separate `claude-watch serve` launchd daemon (second TCC grant, fights
over `engine.lock`); relying on Anthropic Remote Control + the official Claude
app (one account at a time, no usage / retry / moves). Remote Control remains a
manual fallback for a single chat.

## Architecture

```
 iPhone (ClaudeRemote)                         Mac (ClaudeWatch.app)
┌───────────────────────────┐   Tailscale   ┌──────────────────────────────────┐
│ SwiftUI screens            │  (WireGuard)  │ Bridge                            │
│ RemoteClient (URLSession)  │◀────────────▶│  HTTP+WS server (Network.fwk)     │
│ Keychain: host + token     │  REST + WS    │  binds 100.x + 127.0.0.1 only     │
│ Notification actions       │  bearer token │  ├─ Snapshot hub ◀── Monitor      │
└──────────▲────────────────┘               │  ├─ ChatFeed (transcript → msgs)  │
           │ APNs                            │  └─ Command router → jobs         │
     Apple Push Service ◀──── HTTP/2 + JWT ──│ Actions (WatchCore)              │
                                             │  ├─ HeadlessRunner (claude -p)    │
                                             │  ├─ DesktopActions (AX / URL)     │
                                             │  └─ RetryEngine, MoveStore        │
                                             │ Pusher (.p8 JWT → APNs)           │
                                             └──────────────────────────────────┘
```

### Units

| Unit | Location | Responsibility | Depends on |
|---|---|---|---|
| `WatchProtocol` | new SwiftPM library, macOS 14 + iOS 18 | Every wire type: `Snapshot` and the models it contains (moved out of WatchCore; WatchCore does `@_exported import WatchProtocol`), `ChatMessage`, `PendingPrompt`, `Command`, `Job`, `WSClientMessage`, `WSServerMessage`, `PairRequest/Response`. Types and Codable only, no logic. | Foundation |
| `ChatFeed` | WatchCore | Turns a transcript `.jsonl` into `[ChatMessage]`, incrementally from a byte offset (same technique as `TranscriptScanner`). Holds back a partial last line. | WatchProtocol |
| `PromptReader` | WatchCore | Reads `pendingToolPermissions` from session records into `PendingPrompt`s (exact shape decided by the M0 spike). | WatchProtocol |
| `HeadlessRunner` | WatchCore | Runs `claude --resume <cliSessionId> -p <text>` for a chat, generalising `CLIRetry` (same binary lookup, token, permission args). Tracks the child process so it can be stopped. Passes `--permission-prompt-tool` pointing at the bridge's prompt tool so tool approvals reach the phone. Refuses when the chat's activity is `working`. | WatchCore, `TokenStore` |
| `DesktopActions` | WatchCore | UI actions in a profile's desktop window, built on the `UIRetry` / `DesktopLink` helpers: `answer(prompt, decision)`, `stop(session)` (Esc), `newChat(profile, cwd, prompt)`. Serialised by one lock. | WatchCore |
| `WatchBridge` | new library target, Sources/WatchBridge/ (linked by ClaudeWatch; a library so it is unit-testable) | Listener, auth, pairing, HTTP routing, WebSocket hub, jobs, audit log. Routes commands through `Monitor.perform`. | WatchCore, Network.framework |
| `Pusher` | ClaudeWatch/Pusher.swift | ES256 JWT (CryptoKit) from the `.p8` key in Keychain, POST to `api.push.apple.com` over URLSession (HTTP/2). Fires on attention events. | WatchProtocol |
| `PairingWindow` | ClaudeWatch/PairingWindow.swift | "Pair iPhone…" window: QR code (CoreImage), countdown, paired devices list with Revoke. | WatchBridge |
| `ClaudeRemote` | iOS/ClaudeRemote.xcodeproj | The app: screens, `RemoteClient`, Keychain, notification categories and actions, Face ID. | WatchProtocol (local SwiftPM path `../`) |

`App.swift` is already over 500 lines. The bridge is its own target and the
pusher and pairing UI are their own files; `App.swift` only starts them.

## Transport and API

Base URL `http://<mac-magicdns-name>:7433` (port configurable, `bridgePort` in
config). Plain HTTP inside the tailnet; WireGuard provides encryption. Every
request except `POST /pair` carries `Authorization: Bearer <token>`.

### Reads

| Endpoint | Returns |
|---|---|
| `GET /v1/snapshot` | `Snapshot` (accounts, usage, forecasts, sessions, queue, moves, locations, profiles) plus `prompts: [PendingPrompt]` and `warnings: [String]` |
| `GET /v1/chats/{id}/messages?before=<cursor>&limit=50` | A page of `[ChatMessage]` (oldest first) and a `before` cursor for the previous page |
| `GET /v1/folders?profile=<id>` | Recent `cwd`s of that profile's sessions, newest first, with the model and permission mode of the last chat in each |

### Commands

`POST`, JSON body, each with a client-generated `requestId` (UUID). The bridge
remembers the last 500 `requestId`s and returns the original response to a
repeated one. The response is `202 {jobId}`, or an immediate error
(`400`, `401`, `404`, `409 busy`).

| Command | Executed by |
|---|---|
| `/v1/chats/{id}/reply {text}` ("Continue" = `text: "continue"`) | `HeadlessRunner`. `409 busy` if the chat is working. Resolves any retry-queue item for the chat first. |
| `/v1/chats/{id}/prompt {promptId, decision: allow\|deny\|allowAlways}` | The headless prompt tool if the prompt belongs to a headless run, else `DesktopActions.answer` |
| `/v1/chats/{id}/stop` | Terminate the headless child if one runs (SIGINT, then SIGTERM after 5 s), else `DesktopActions.stop` |
| `/v1/chats/new {profileId, cwd, prompt, model?, permissionMode?}` | `DesktopActions.newChat` |
| `/v1/queue/{itemId}/retry`, `/v1/queue/{itemId}/cancel` | `RetryEngine` via `Monitor` |
| `/v1/accounts/{profileId}/mode {mode: ui\|cli\|off}` | `Monitor.setRetryMode` |
| `/v1/moves {sessionId, from, to}`, `/v1/moves/{id}/undo`, `/v1/moves/{id}/cancel`, `/v1/moves/restart` | `Monitor.requestMove / undoMove / cancelMove / restartAndRunMoves` |
| `/v1/devices {apnsToken, environment: sandbox\|production}` | Store the push token on this device's record |
| `DELETE /v1/devices/self` | Unpair this device |

A `Job` is `{jobId, requestId, command, status: accepted|running|done|failed|blocked, reason?}`.
`failed` means the action ran and did not succeed; `blocked` means a missing
precondition (permission, draft in composer, window unreachable). The phone
shows `reason` verbatim.

### WebSocket `GET /v1/stream`

Client → server: `{"subscribe": chatId}`, `{"unsubscribe": chatId}`, `{"ping": n}`.
At most one subscription per connection (the chat on screen).

Server → client:

- `snapshot` — full, once on connect.
- `snapshotPatch` — changed / removed accounts, sessions, queue items, moves, prompts; at most one per Monitor poll, omitted when nothing changed.
- `messages {chatId, messages}` — new `ChatMessage`s for the subscribed chat. While a subscription exists, `ChatFeed` checks that transcript every 1 s (mtime + size), independent of the Monitor's 15 s poll.
- `prompt {chatId, prompt | null}` — a prompt appeared or cleared.
- `job` — status changes of this device's jobs.
- `pong`.

Server heartbeat every 20 s. The client reconnects with exponential backoff
(1 s → 30 s) and resubscribes; the full snapshot on reconnect means no state is
lost.

### Wire types (sketch)

```swift
public struct ChatMessage: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case user, assistant, tool, error, system }
    public var id: String            // transcript entry uuid (+ ":n" for split content blocks)
    public var kind: Kind
    public var at: Date
    public var text: String          // markdown for assistant/user; one-liner for tool
    public var toolName: String?     // "Bash", "Edit", ...
    public var toolOK: Bool?         // from the matching tool_result
}

public struct PendingPrompt: Codable, Hashable, Sendable, Identifiable {
    public enum Source: String, Codable, Sendable { case desktop, headless }
    public var id: String
    public var chatId: String
    public var profileId: String
    public var toolName: String
    public var summary: String       // "swift build", "Edit Sources/…/App.swift"
    public var detail: String?       // full command / path, truncated to 4 KB
    public var source: Source
    public var at: Date
    public var canAllowAlways: Bool
}
```

Tool one-liners: `Edit`/`Write` → "Edited <file>", `Bash` → "Ran <first 80 chars>",
`Read` → "Read <file>", `Grep`/`Glob` → "Searched <pattern>", `Task`/`Agent` →
"Agent: <description>", others → "<ToolName>". ✓/✗ from the paired
`tool_result.is_error`. Subagent transcripts are not shown in v1; the parent's
Agent one-liner stands in for them.

## Permission prompts

Two sources:

1. **Desktop prompts.** A chat running in a desktop window records pending
   prompts in its session record (`pendingToolPermissions`). `PromptReader`
   turns them into `PendingPrompt(source: .desktop)`. Answering focuses that
   profile's window, opens the chat (`claude://code/continue?session=`), finds the
   prompt's buttons via AX and presses the one matching the decision, then gives
   focus back. After pressing, the job waits up to 10 s for the prompt to clear
   from the record: cleared → `done`, still there → `failed`.
2. **Headless prompts.** `HeadlessRunner` starts `claude` with
   `--permission-prompt-tool mcp__claudewatch__approve` and an `--mcp-config` for a
   stdio MCP server that is the `claude-watch` binary itself
   (`claude-watch prompt-tool --run <runId>`). The tool call reaches the bridge
   over the local socket `~/Library/Application Support/claude-watch/bridge.sock`
   and blocks until the phone answers or 10 min pass (→ deny). These prompts are
   `PendingPrompt(source: .headless)`.

`allowAlways` is offered only where the source supports it (desktop: if the
button exists; headless: adds the rule for the session only).

**M0 spike.** Before M3 is built, and at the start of the project: capture a
real `pendingToolPermissions` payload (trigger a prompt in a scratch folder),
and try pressing Allow / Deny through AX with a `claude-watch probe-prompt`
dry run. Findings are written into this spec. If AX pressing is not reliable,
desktop prompts get only an **Open on Mac** action plus the notification;
headless prompts are unaffected.

## Push notifications

Sent only for paired devices with an APNs token, and only for events the device
has enabled (preferences live on the device record, set from the Mac tab).

| Event | Category | Actions | Collapse id |
|---|---|---|---|
| Prompt appeared | `PROMPT` | Allow (auth required), Deny, Open | `prompt-<chatId>` |
| Chat finished its turn | `CHAT` | Open | `chat-<chatId>` |
| Chat failed (API error / limit) | `CHAT` | Continue, Open | `chat-<chatId>` |
| Limit reset / account free / cap ≈ 30 min | `ACCOUNT` | Open | `acct-<profileId>` |

"Chat finished" fires on a `working → idle` transition of a chat that the
phone has touched in the last 24 h (replied to, created, or had open), so
unrelated chats don't notify. The other events reuse the Monitor's existing
`WatchEvent` transitions.

Payloads contain account name, chat title and the prompt summary (≤ 120
chars), never file contents. A notification action runs in the background:
it POSTs the command and waits up to 20 s for the job result. If the Mac is
unreachable (Tailscale off), it posts a local notification "Couldn't reach
your Mac — open to retry".

The `.p8` key, key id and team id are stored with
`claude-watch set-apns-key <file> --key-id <id> --team-id <id>` (Keychain). The
JWT is cached for 50 min. `410 Unregistered` removes the token from the device.

## iOS app

Tabs: **Chats**, **Accounts**, **Mac**. The Chat screen and New chat sheet sit on
top.

- **Chats** — every chat of every account, grouped: *Needs you* (pending
  prompt, failed, limited), *Working* (with the current task's `activeForm`),
  *Recent*. Rows: account colour chip, title, folder name, relative time.
  Search and account filter. **＋** → New chat.
- **Chat** — header (title, account · folder, Stop while working), collapsible
  task list, message list (markdown via `AttributedString`, tool one-liners with
  ✓/✗, older pages on scroll up, live while open), a prompt card pinned above
  the composer (Deny / Allow / Always), composer with a quick **Continue** when
  the chat failed on a limit. While working, the composer is replaced by
  "Working… · Stop". Menu: Move to account…, Open on Mac, Copy session id.
- **New chat** — account picker (with state and 5 h %), folder picker (recent
  folders for that account, or a typed path), prompt, *Advanced*: model and
  permission mode, defaulting to that folder's last chat.
- **Accounts** — a card per account: state, 5 h and weekly bars with the
  forecast text the Mac already produces ("cap 4:10" / "safe"), tokens/h.
  Detail: usage chart (Swift Charts, from the account's samples), its chats,
  retry mode picker. Below: Retry queue (retry now, cancel) and Moves (undo,
  cancel, "Restart windows to finish").
- **Mac** — connection state, Mac name, last seen, bridge warnings (e.g.
  "Accessibility permission missing — prompts can't be answered"), notification
  preferences per event, Face ID lock toggle, Unpair.

Offline: the last snapshot is cached on disk and shown with "Last updated 2m
ago · reconnecting". Commands are disabled while offline; nothing is queued.

State: one `@Observable` `RemoteStore` holds the snapshot, prompts, the open
chat's messages and jobs, fed by `RemoteClient` (REST + WS). Views read from the
store; commands go through the store so pending jobs show inline ("Sending…").

## Security

- The listener binds only to the Mac's Tailscale address(es) (`100.64.0.0/10`,
  and the tailnet IPv6 `fd7a:115c:a1e0::/48`) and `127.0.0.1`. Other peers are
  closed before any HTTP parsing. If no Tailscale address exists, only loopback
  is bound and the menu shows a warning.
- **Pairing**: "Pair iPhone…" shows a QR code with `{host, port, code}`; `code` is
  6 digits, single use, valid for 2 min, and `POST /pair` is only accepted
  while the pairing window is open. Five wrong codes close the window. The
  response is a 256-bit random token. The Mac stores `SHA-256(token)`, device
  name, created / last seen, APNs token and preferences in `devices.json`; the
  phone stores the token in Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,
  so notification actions work while locked). Token comparison is constant-time.
- **Tailscale identity** (config `requireTailnetOwner`, default on): the bridge
  runs `tailscale whois --json <peer>` once per peer IP (cached 10 min) and
  accepts only devices owned by the same user as the Mac. If the CLI is
  unavailable, the check is skipped and a warning is shown.
- **Face ID** (default on): required to open the app, and again for Allow on
  a Bash prompt and for New chat. The `PROMPT` Allow action uses
  `.authenticationRequired`.
- **Audit**: every command is appended to `remote-log.jsonl`
  (`at, device, command, target, result`). The Mac menu shows the last remote
  action. Revoking a device (Mac menu or the phone's Unpair) deletes its record;
  its open WebSocket is closed at once.

## Error handling

| Situation | Result |
|---|---|
| Reply while the chat is working | `409 busy` — "Claude is still working. Stop it first or wait." |
| Desktop window not running | `DesktopLink.ensureRunning` launches it, as retries do |
| Accessibility / Automation missing | `blocked` + a bridge warning |
| Unsent draft in the desktop composer | `blocked` — "There's an unsent draft on the Mac" |
| Prompt already answered on the Mac | `failed` — "Prompt no longer pending"; the card disappears via the next patch |
| Headless run hits a usage limit | The chat enters the existing retry queue |
| No CLI token for the profile (headless reply) | `blocked` — "Run `claude-watch set-token <profile>` on the Mac" |
| Push fails / no APNs key | Logged; the app still shows everything on next open |
| Bridge port in use | Bridge stays off, error in the Mac menu; the rest of ClaudeWatch is unaffected |
| Mac asleep | Phone shows "Mac unreachable". Optional "Keep Mac awake while a phone is paired" (IOKit power assertion; optional "only on AC power") |

Concurrency: commands execute on the Monitor queue via `Monitor.perform`, so they
cannot race the retry engine or moves. All `DesktopActions` share one lock with
`UIRetry`, so two AX actions never interleave. At most one headless run per chat.

## Config additions

`config.json`: `bridgeEnabled` (default true), `bridgePort` (7433),
`requireTailnetOwner` (true), `keepAwakeWhenPaired` (false),
`keepAwakeOnlyOnAC` (true). New files next to it: `devices.json`,
`remote-log.jsonl`, `bridge.sock`.

## Repo layout

```
Package.swift                 + WatchProtocol library (macOS 14, iOS 18)
Sources/WatchProtocol/        wire types
Sources/WatchCore/            + ChatFeed, PromptReader, HeadlessRunner, DesktopActions
Sources/WatchBridge/          Listener, HTTP, WebSocket, Auth, Pairing, Jobs, AuditLog
Sources/ClaudeWatch/          + Pusher.swift, PairingWindow.swift
Sources/claude-watch/         + prompt-tool, set-apns-key, probe-prompt subcommands
Tests/WatchCoreTests/         + ChatFeed, PromptReader, HeadlessRunner tests
Tests/WatchBridgeTests/       listener / auth / pairing / WS tests
iOS/ClaudeRemote.xcodeproj    iOS app, depends on WatchProtocol via local path
```

## Testing

- **WatchProtocol**: Codable round trips; golden JSON fixtures shared by the Mac
  and iOS test targets so the two sides cannot drift.
- **ChatFeed**: fixture transcripts (existing `transcript.jsonl` plus new ones
  with tool calls, tool errors, rate-limit errors, subagents) → expected
  messages; appending lines yields only the new ones; a partial trailing line is
  held back until complete.
- **PromptReader**: fixture session records from the M0 spike.
- **HeadlessRunner**: a stub `claude` shell script injected as the binary →
  busy refusal, stop (SIGINT then SIGTERM), prompt-tool allow / deny / timeout.
- **WatchBridge**: a real listener on 127.0.0.1 with a fake command handler →
  missing / wrong token 401, non-allowed peer dropped, pairing code expiry and
  single use, 5-failure lockout, `requestId` idempotency, WS snapshot → patch →
  subscribed messages, revoke closes the socket.
- **DesktopActions**: not unit-testable (AX). `claude-watch probe-prompt` dry
  run plus a manual checklist per action.
- **iOS**: view-model tests against a `MockRemoteClient`; SwiftUI previews from
  fixture snapshots; a manual end-to-end pass on the phone over Tailscale
  (cellular, not Wi-Fi) for each milestone.

## Milestones

| # | Delivers | Pieces |
|---|---|---|
| M0 Spike | `pendingToolPermissions` shape; AX press of Allow / Deny works or not | throwaway probe, findings in this spec |
| M1 Read-only remote | Pairing; Chats and Accounts tabs; live usage and queue; live chat view | WatchProtocol, ChatFeed, WatchBridge (reads + WS), PairingWindow, iOS skeleton |
| M2 Act | Reply / Continue, Stop, retry queue control, retry mode, move / undo / restart | HeadlessRunner, command router, jobs, audit log |
| M3 Prompts & push | Prompt cards; Allow / Deny in app and from notifications; all push events; Face ID | PromptReader, DesktopActions.answer, prompt tool, Pusher, notification categories |
| M4 New chat & polish | New chat sheet and folder picker; keep-awake; offline cache; tailnet owner check | DesktopActions.newChat, settings |

## Setup the user does once

1. Apple Developer portal: App ID for ClaudeRemote with Push Notifications;
   an APNs auth key (`.p8`). Then on the Mac:
   `claude-watch set-apns-key <file> --key-id <id> --team-id <id>`.
2. Install Tailscale on the iPhone, signed into the same tailnet as the Mac.
3. Grant the existing Accessibility and Automation permissions to ClaudeWatch
   (already needed for UI retries).

## Out of scope for v1

Android; iPad-specific layout; showing subagent transcripts; expanding tool
calls to diffs / output; attachments and images in replies; editing the retry
config other than per-account mode; more than one Mac.
