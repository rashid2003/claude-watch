# claude-watch

A small menu-bar app and terminal dashboard that watches several Claude desktop
profiles on this Mac, and resumes chats that died on a usage limit once it resets.

- **Status per account**: free / working / limited, running window, live chats and their task lists
- **Usage**: 5-hour and weekly %, token totals, current pace
- **Forecast**: time until each cap at the current pace, or "safe", meaning the window resets first
- **Notifications**: an account becomes free, a limit resets, a cap is ~30 min away, a retry finishes
- **Auto-retry**: after a limit resets, sends `continue` to every chat that failed on it,
  using UI automation, the CLI (`--resume`), or notify-only, chosen per account

Everything is read from local files. Nothing is sent anywhere.
Memory is about 25–50 MB, with idle CPU near 0.

## Install

```bash
./install.sh
```

This builds `~/Applications/ClaudeWatch.app` (menu bar, no Dock icon) and
`~/.local/bin/claude-watch`, then launches the app. On first launch, allow:

- **Notifications**
- **Accessibility**, needed for UI-mode retries (System Settings › Privacy & Security › Accessibility)
- **Automation → Claude**, used to open a chat in the right window

## Terminal

```bash
claude-watch                  # live dashboard: q quit · r refresh · R retry due chats now
claude-watch status [--json]  # one-shot
claude-watch queue [--stats]  # retry queue / UI-vs-CLI success comparison
claude-watch retry [profile]  # retry waiting chats now, even while the account is still limited
claude-watch retry --item <session-id>  # retry one queued chat now (also restarts one that gave up)
claude-watch mode <profile> ui|cli|off
claude-watch probe [profile]  # dry-run of the UI path: opens a chat, types nothing
claude-watch set-token <profile>
claude-watch profiles
claude-watch move "title words" --to 2 [--now]   # move a chat to window claude-2-… (see below)
claude-watch moves [--undo <id> [--now] | --cancel <id> | --now]
```

## Moving chats

Hover a chat in the popover and click ⇄, or open **All chats…** on an account, to move a chat to
another window / org. Claude windows only read their chat list at start-up, so the move runs while
both windows are closed: choose **Restart now** (Claude Watch quits them, moves the chat, reopens them)
or **Later** (it runs the next time both are closed). Every move is backed up in
`~/Library/Application Support/claude-watch/moves/` and can be undone from **Recent moves** or with
`claude-watch moves --undo <id>`. Name orgs in the menus with `orgNames` in `config.json`.

```bash
claude-watch move "chat title words" --to 2          # window claude-2-…
claude-watch move local_… --to 1:eb9c --now          # window 1, org eb9c…, restart now
claude-watch moves                                   # pending + history
```

## Retry modes

| Mode | How | Needs |
|---|---|---|
| `ui` (default) | Opens the chat in that profile's own Claude window (`claude://code/continue?session=…` sent to that process), types the message, presses Return, then gives focus back to the previous app. Skips chats with an unsent draft. | Accessibility + Automation |
| `cli` | `claude --resume <id> -p continue` in the chat's folder, using that profile's bundled CLI and the same permission mode as the chat | a token per profile: run `claude setup-token` while signed in as that account, then `claude-watch set-token <profile>` (stored in Keychain) |
| `off` | Notification only ("X is free: 3 chats to resume") | — |

Every attempt is checked against the transcript. A new reply means done. Hitting
the limit again sends the chat back to the queue. No reply within 4 min counts as
a failed attempt (max 3). Missing permissions pause the queue without using up
attempts. Chats you continue yourself drop out of the queue. `claude-watch queue --stats`
compares the two modes.

## How accounts are identified

- Profiles are `~/Library/Application Support/Claude` plus each real folder in
  `~/Claude-Profiles/`. Names come from the launcher applets in `~/Applications`.
- Limits apply per **account + org**. Profiles signed into the same account and org
  are shown as one row (e.g. the default Claude.app window).
- Chats are mirrored between profiles, so each one belongs to the profile whose
  window actually runs it. This is seen live from the desktop's CLI processes
  (only `CLAUDE_CODE_HOST_SESSION_ID` / `ACCOUNT_UUID` / `ORGANIZATION_UUID` are read) and remembered.
- Usage % comes from the desktop app's own samples (`plan-usage-history.json`, ~15 min).
  Between samples it's extrapolated from tokens, using a tokens-per-% ratio
  learned for each account.

## Config

`~/Library/Application Support/claude-watch/config.json`:

```json
{
  "defaultRetryMode": "ui",
  "retryMessage": "continue",
  "retryDelaySeconds": 60,
  "maxAttempts": 3,
  "maxFailureAgeHours": 12,
  "warnBeforeCapMinutes": 30,
  "pollSeconds": 15,
  "profiles": { "work": { "retryMode": "cli", "name": "Work", "hidden": false } },
  "cliExtraArgs": []
}
```

Logs, queue state and the retry log are in the same folder.

## iPhone remote (ClaudeRemote)

`iOS/ClaudeRemote.xcodeproj` is an iPhone app that talks to a bridge inside
ClaudeWatch.app. From the phone you can:

- see every account's status, usage, forecast and retry queue;
- read chats live and reply to them;
- stop a working chat;
- answer permission and question prompts;
- start new chats;
- retry now, cancel a retry, switch retry mode;
- move chats.

**Reaching the Mac.** The bridge listens on port 7433, but only on the Mac's
[Tailscale](https://tailscale.com) addresses and `127.0.0.1`. Other peers are
dropped before any HTTP is read. Install Tailscale on the Mac and on the iPhone,
signed into the same tailnet, and the phone reaches the Mac from anywhere.

**Pairing.**
1. In the menu, click **iPhone…**. This shows a QR code and a 6-digit code.
2. In ClaudeRemote, tap **Pair** and scan the QR code, or enter the host, port
   and code by hand.

The code works once, for 2 minutes, and five wrong tries close it. The phone
gets a random token. The Mac stores only its SHA-256, in `devices.json`
(mode 600). You can revoke devices in the same window. Every remote action is
logged to `remote-log.jsonl`.

**How commands run.**

| Action | How |
|---|---|
| Reply | Headless `claude --resume <id> -p <text>` with that profile's CLI token (`claude-watch set-token <profile>`). Without a token, it's typed into the desktop window instead. Refused while the chat is working. |
| Prompts in headless replies | They go to the phone through `--permission-prompt-tool` (the `claude-watch prompt-tool` MCP server). |
| Prompts in the desktop window | Found from the transcript: an unanswered tool call with no new output. Answered by pressing the window's button through Accessibility. |
| Stop | SIGINT to the headless run, or the window's Stop button, or Esc |
| New chat | `claude://code/new?folder=…&q=…` sent to that profile's window |

**Push notifications** (optional). Needed for prompts, finished or failed
chats, and account events. In the Apple Developer portal, create the App ID
`dev.lajward.ClaudeRemote` with Push Notifications and an APNs auth key (`.p8`),
then run:

```bash
claude-watch set-apns-key AuthKey_XXXX.p8 --key-id XXXX --team-id YYYY
```

The key is kept in the Keychain. The Mac sends straight to Apple's push
service; there is no other server.

**Building the app.** Open `iOS/ClaudeRemote.xcodeproj`, then set your team
under Signing & Capabilities and run it. In the Simulator, pair with
`127.0.0.1` and port `7433`.

Set `"bridgeEnabled": false` in the config to turn the bridge off. Two related
settings are `"keepAwakeWhenPaired"` (keeps the Mac awake while a phone is
paired) and `"keepAwakeOnlyOnAC"`.

## Development

```bash
swift build && swift test
swift run claude-watch status
```

`Sources/WatchCore` holds the readers, forecaster and retry engine.
`Sources/claude-watch` is the terminal UI and `Sources/ClaudeWatch` is the menu-bar app.
`Sources/WatchProtocol` holds the wire types shared with the iPhone app, and
`Sources/WatchBridge` is the HTTP/WebSocket bridge, pairing, prompt broker and push sender.
