# Session Watch roadmap

The aim is for the phone to feel like the Claude app itself. You see what every chat is doing, answer it from anywhere, and never lose what you typed.

Status: ✅ shipped · 🚧 in progress · 📋 planned. Branch names show where work lives until it's merged.
Last updated: 2026-10-08.

## Shipped

| | Item | Notes |
|---|---|---|
| ✅ | Relay at `relay.sessionwatch.lajward.co` | Cloudflare Worker + Durable Object, end-to-end encrypted, key pinned in the pairing QR |
| ✅ | Relay by default, Tailscale opt-in | PR rashid2003/claude-watch#1. Connect via: relay (default) · auto · direct |
| ✅ | Phones paired before the relay pick up its details | `/v1/status` carries `relay` |

## In review: `queue-cache-tool-groups`

| | Item | Notes |
|---|---|---|
| 🚧 | Queue replies while Claude works | Mac `ReplyQueue` (`reply-queue.json`). A chat's queued replies are sent together when the turn ends. ✕ removes one |
| 🚧 | Faster chat loading | Mac `TranscriptCache` (parsed transcripts in memory). Phone `MessageCache` (newest 300 messages × 40 chats on disk) and preloads the 6 most recent chats |
| 🚧 | Fold tool calls | Two or more in a row fold into one row. Menu: hide tool calls / collapse all |

Mac 0.4.0 is installed. iPhone build from this branch is uploading to TestFlight.

## Now

| | Item | Owner | Notes |
|---|---|---|---|
| 🚧 | **"Mac unreachable" after the Mac restarts or the app is suspended** | main session | The phone's relay proxy can reuse a dead local listener. Reset it on transport failure and check the listener is ready |
| 🚧 | **Scrolling while unreachable starts a reconnect** | main session | Scroll / appear handlers shouldn't trigger reconnects; one backoff loop only |

## Next (subagents, one worktree each)

| | Item | Branch | Scope |
|---|---|---|---|
| 📋 | **Allow / Deny in the notification** | `feat/actionable-prompts` | Mac sends prompt pushes with a category; iPhone registers Allow / Always / Deny actions and answers from the notification (background task, no app launch) |
| 📋 | **Open at login** | `feat/launch-at-login` | Mac Settings toggle using `SMAppService.mainApp`, on by default after first run, reflects System Settings changes |
| 📋 | **Drafts follow you between devices** | `feat/draft-sync` | Unsent text in the phone composer shows on the Mac and the other way round. The Mac reads/writes the Claude desktop composer via Accessibility, never overwriting text the user is typing |
| 📋 | **Live Activity shows when the Mac is unreachable** | `feat/live-activity-offline` | Mac sets `staleDate` and sends heartbeats. Widget renders a "disconnected" state when stale; the phone marks it locally when it loses the Mac |
| 📋 | **See what a chat is doing, like the Claude app** | `feat/live-work` | Running commands (with elapsed time), subagents and their current step, and background tasks, shown in the chat and the chats list |

## Later

- iPhone version shown on the Mac's paired-devices list; warn when the phone is older than the Mac's protocol
- Release script bumps the Mac build version automatically (today it reuses `0.x.0` until changed)
- Relay metrics (streams, errors) without logging content

## Decisions

- **Relay first.** On rashid's network Tailscale can't reach its control plane. The relay works anywhere, adding about 0.2–0.7 s per new stream.
- **Queued replies go out together as one message**, like the desktop app's queue, rather than one turn each.
- **The cache is only for speed.** The Mac's copy always replaces what the phone cached once it arrives.
