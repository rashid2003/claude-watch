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
claude-watch mode <profile> ui|cli|off
claude-watch probe [profile]  # dry-run of the UI path: opens a chat, types nothing
claude-watch set-token <profile>
claude-watch profiles
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

## Development

```bash
swift build && swift test
swift run claude-watch status
```

`Sources/WatchCore` holds the readers, forecaster and retry engine.
`Sources/claude-watch` is the terminal UI and `Sources/ClaudeWatch` is the menu-bar app.
