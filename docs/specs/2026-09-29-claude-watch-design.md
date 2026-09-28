# claude-watch — design

Lightweight monitor for several Claude desktop profiles running on one Mac.
Shows each account's 5-hour / weekly usage, working status, task lists, token
burn and forecasts; notifies when an account frees up; re-sends "continue" to
chats that died on a usage limit once that limit resets.

## Front ends

- `ClaudeWatch.app` — SwiftUI menu-bar extra (no Dock icon). Owns notifications.
- `claude-watch` — terminal dashboard + subcommands (`status --json`, `queue`,
  `retry`, `set-token`).

Both share `WatchCore`. Only one process at a time runs the retry engine
(`flock` on `engine.lock`); the other is read-only for the queue.

## Data sources (all local, read-only)

| Data | Source |
|---|---|
| Profiles | `~/Library/Application Support/Claude` (default) and `~/Claude-Profiles/*` |
| Profile names | Launcher applets whose script contains `--user-data-dir=…/account-N` |
| 5h / weekly % | `<profile>/plan-usage-history.json` samples `{t, org, u:{fh, sd}}` (~15 min cadence) |
| Sessions | `<profile>/claude-code-sessions/<accountUuid>/<orgUuid>/local_*.json` |
| Failed on limit | session `error`/`errorAt` + transcript entry `error:"rate_limit"` with `quotaLimits.resetsAt` |
| Tokens / activity | `~/.claude/projects/*/<cliSessionId>.jsonl` (+ `<id>/subagents/*.jsonl`) |
| Tasks | `~/.claude/tasks/<cliSessionId>/*.json` |
| Running instance | `ps` args `--user-data-dir=<profile>` (default profile: no flag) |

Tokens are attributed by the session's account UUID, so profiles that share an
account share usage.

## Status rules

- **limited** — a rate-limit `resetsAt` in the future, or latest `fh`/`sd` ≥ 100.
- **working** — any session whose transcript's last entry is not a finished
  assistant turn and is < 10 min old, or whose transcript changed < 30 s ago.
- **free** — neither.

## Forecast

- Weighted tokens = input + 1.25·cache_write + 0.1·cache_read + 5·output.
- `pctPerToken` learned per account from consecutive usage samples in the same
  window (Δ% ÷ Δweighted tokens), default until learned.
- Live % = last sample % + tokens since sample × `pctPerToken`.
- Rate = blend of sample slope (last 60 min for 5h, 12 h for weekly) and token
  rate over last 30 min × `pctPerToken`.
- ETA = (100 − live%) ÷ rate. If ETA is after the window's reset → "resets first".
- Window reset: `resetsAt` from a rate-limit error if known, else window start
  (first rise after a drop to ~0) + 5 h / 7 d.

## Retry engine

1. A session is queued when its last transcript entry is a `rate_limit` error.
2. Due at `resetsAt + retryDelaySeconds` (default 60).
3. Executed per the account's mode:
   - **ui** — Apple Event `GURL claude://code/continue?session=<localId>` sent to
     that profile's own Claude process (launched if not running), activate,
     focus composer via AX, type message, Return. Needs Accessibility +
     Automation permission.
   - **cli** — `<profile bundled claude> --resume <cliSessionId> -p <message>`
     in the session cwd, with `CLAUDE_CODE_OAUTH_TOKEN` from Keychain
     (`claude-watch` / profile id), mirroring the session's permission mode.
   - **off** — notify only.
4. Verified by watching the transcript: new non-error assistant entry → done;
   new rate-limit → requeued; nothing within 4 min → attempt failed (max 3).
5. If the user continues the chat manually first, the item resolves itself.
6. Every attempt is logged (`retry-log.jsonl`) with mode + outcome so UI and CLI
   can be compared (`claude-watch queue --stats`).

## Storage

`~/Library/Application Support/claude-watch/`: `config.json`, `state.json`
(queue + transitions), `scan-cache.json` (transcript offsets + 5-min token
buckets, 7-day retention), `retry-log.jsonl`, `logs/`.
