# Session Watch roadmap

The aim is for the phone to feel like the Claude app itself. You see what every chat is doing, answer it from anywhere, and never lose what you typed.

Status: ✅ shipped · 🧪 on `next`, being tested in Session Watch Next · 🚧 in progress · 📋 planned.
Last updated: 2026-10-09.

## How work lands

1. Each feature is built on its own `feat/*` branch, then merged into **`next`** (worktree `~/Development/claude-watch-next`).
2. **Session Watch Next** (`VARIANT=next scripts/release-mac.sh`) runs next to the installed app: bundle `dev.lajward.SessionWatch.next`, data in `claude-watch-next`, port 7434, its own relay room. It's tested with the iPhone Simulator, so the installed Mac app and the TestFlight build on the phone stay untouched.
3. When a task is done, it's merged to `main`, then Session Watch (Mac) and the TestFlight iPhone app are released from it. Session Watch Next is Mac-only: there is no iPhone Next app.

## Shipped

| | Item | Notes |
|---|---|---|
| ✅ | Relay at `relay.sessionwatch.lajward.co` | Cloudflare Worker + Durable Object, end-to-end encrypted, key pinned in the pairing QR |
| ✅ | Relay by default, Tailscale opt-in | PR rashid2003/claude-watch#1. Connect via: relay (default) · auto · direct |
| ✅ | Phones paired before the relay pick up its details | `/v1/status` carries `relay` |
| ✅ | Queue replies while Claude works | Mac `ReplyQueue`. A chat's queued replies are sent together when the turn ends. ✕ removes one. Installed Mac 0.4.0 |
| ✅ | Faster chat loading | Mac `TranscriptCache`; phone `MessageCache` (300 messages × 40 chats) and preloads the 6 most recent chats |
| ✅ | Fold tool calls | Two or more in a row fold into one row. Menu: hide tool calls / collapse all |
| ✅ | Recover from a dead relay listener; no reconnect storms | Phone build 202610080636. Pull to refresh only skips the backoff wait |

## On `next` (testing in Session Watch Next)

| | Item | Branch | Notes |
|---|---|---|---|
| 🧪 | **Allow / Deny in the notification** | `feat/actionable-prompts` | Categories `PROMPT`, `PROMPT_ALWAYS`, `PROMPT_SHELL(_ALWAYS)`. Allow/Always need Face ID; Deny works locked. With the app lock on, Bash prompts offer only Deny/Open. Answered in a 25 s background task; if it fails, a local notification says so |
| 🧪 | **Open at login** | `feat/launch-at-login` | `SMAppService.mainApp`, registered once on first launch, Settings toggle shows the real status and handles "requires approval" |
| 🧪 | **Drafts follow you** | `feat/draft-sync` | Phone ↔ Mac via `POST /v1/chats/{id}/draft` and `Snapshot.drafts`. The desktop composer is read (2 s, only for chats a phone has open), never written |
| 🧪 | **Live Activity shows "Mac offline"** | `feat/live-activity-offline` | 12-min `stale-date` and 5-min heartbeats (priority 5). The phone marks it offline after 30 s without the Mac in the foreground |
| 🧪 | Session Watch Next | `next` | Side-by-side build: shares the engine lock, skips keychain reads and the login item |
| 🧪 | Chats list rows follow their section | `next` | A chat moving from working to recent could keep its old row (lazy stack keyed rows by id across sections) |
| 🧪 | Scan cache v3 | `next` | Old caches rescan once so live work is right from the start (~1–2 min on first launch) |
| 🧪 | Revokes are logged | `next` | `remote-log.jsonl` gets `revoke … by mac/phone`. A device list emptied at 06:37 today had no trace |
| 🧪 | **See what a chat is doing, like the Claude app** | `feat/live-work` | `WorkTracker` follows running tool calls, subagents (their own `subagents/agent-*.jsonl` files) and background shells/monitors; ends them on results, task notifications (user entries, mid-turn `queued_command` and `task_status` attachments), TaskStop or interrupts. Phone: "live" panel under the tasks with timers and each subagent's current step; chats list shows `↳ 2 agents · Bash: swift test`. Checked in the Simulator against Session Watch Next |
| 🧪 | **iPhone app version on the Mac; update hints** | `feat/devices-offline` | `WireProtocol.current = 2` (no number = 1; bump rules in `Versions.swift`). The phone sends `X-Session-Watch-Version/-Build/-Protocol` on every request; the Mac keeps `Device.client` and shows "App 1.3 (build) · protocol 2" under each paired device, with "Update Session Watch on this iPhone" when it's older. `/v1/status` carries `protocolVersion`; on a mismatch the phone shows a dismissible banner: "Update Session Watch from TestFlight" or "… on the Mac". Never blocks |
| 🧪 | **Live Activity goes offline when the Mac sleeps or quits** | `feat/devices-offline` | On `willSleep` and on quit the Mac sends one priority-10 update with `offline: "sleep"/"quit"`, `connected: false` and a stale date of now (so older widget builds show offline too), waiting up to 2 s. Nothing more until `didWake`, when the next snapshot goes out at once. Says "Mac asleep" / "Mac app quit". A push that never left the Mac is retried on the next snapshot |
| 🧪 | **Mac release script bumps the version** | `feat/release-tooling` | `scripts/MAC_VERSION` holds the last release. Default bumps the patch; `BUMP=minor\|major\|none` or `VERSION=x.y.z`. Written only after notarization succeeds, never for `VARIANT=next`. `DRY_RUN=1` prints the version and stops. No commits or tags |
| 🧪 | **Relay metrics without content** | `feat/release-tooling` | Streams, bytes each way, errors by kind, auth failures, active Mac rooms; per deployment and in total. Rooms batch counters for 5 s into a `RelayMetrics` Durable Object. `GET /v1/metrics` with the `METRICS_TOKEN` secret. No payloads, ids, keys or IPs. Not deployed yet |

## Needs a real device

- Notification actions from the Lock Screen, with the app killed, over the relay
- Live Activity offline look in every Dynamic Island size; no false "offline" from late low-priority pushes
- Desktop → phone drafts: whether the Mac can tell which chat a Claude window shows (URL id or title). If it can't, desktop drafts never appear
- Accessibility for Session Watch Next is a separate permission (its own bundle id)
- Lid closed / Apple menu › Sleep: the Live Activity says "Mac asleep" within seconds; on wake it's current again without opening the app. Also quitting Session Watch ("Mac app quit"), and a dark wake (Power Nap) not flipping it back
- The goodbye push leaves before Wi-Fi drops on sleep (the Mac waits at most 2 s); if not, it still goes stale after 12 min as before
- Paired devices show the TestFlight build's version once it has connected; an old TestFlight build shows "version unknown" plus the update warning
- Relay mode in the iPhone **Simulator**: the in-app `NWListener` never accepts (`SO_NECP_LISTENUUID failed`), so the Simulator shows "mac unreachable" over the relay. Use direct mode there (debug builds pair with `SIMCTL_CHILD_SW_PAIR='<QR JSON>'`). Real phones are unaffected

## Needs you

- **Relay metrics**: after `feat/release-tooling` is merged and the relay deployed, set the token once: `cd relay && npx wrangler secret put METRICS_TOKEN` (a long random value, e.g. `openssl rand -hex 24`). Until then `/v1/metrics` answers 404. Read: `curl -H "Authorization: Bearer <token>" https://relay.sessionwatch.lajward.co/v1/metrics`
- **Mac release**: commit `scripts/MAC_VERSION` after a release ("Release the Mac app as x.y.z"); the script doesn't

## Later


## Decisions

- **Relay first.** On rashid's network Tailscale can't reach its control plane. The relay works anywhere, adding about 0.2–0.7 s per new stream.
- **Queued replies go out together as one message**, like the desktop app's queue, rather than one turn each.
- **Phone drafts stay in Session Watch on the Mac, not in the Claude composer.** Writing there means posting keystrokes to a background Electron window (it needs focus, so it would steal it) or setting the editor's value through Accessibility (its own state doesn't follow, so the text can vanish or be sent wrong). Reading the desktop composer is safe and is done.
- **The cache is only for speed.** The Mac's copy always replaces what the phone cached once it arrives.
- **New work runs in Session Watch Next first**, so the installed app and the phone keep working while features are tried.
