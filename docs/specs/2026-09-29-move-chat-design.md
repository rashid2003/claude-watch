# Move a chat to another window / account — design

Adds a button to each chat that moves it to another Claude window (profile) and
org. Builds on the data layout in `2026-09-29-claude-watch-design.md`.

## Background

- A Code-tab chat is one record: `<profile>/claude-code-sessions/<accountUuid>/<orgUuid>/local_<id>.json`.
  Archived chats are also listed in that folder's `archived-sessions.idx`
  (`{"v":1,"archived":["local_…"]}`).
- The conversation itself is the CLI transcript in `~/.claude/projects/<encoded cwd>/<cliSessionId>.jsonl`
  (+ `<cliSessionId>/` for subagents and tool results). `~/.claude` is shared by
  every profile, so the transcript does not have to move with the record.
  `<encoded cwd>` is the cwd with `/` and `.` replaced by `-`; the same session
  can appear under more than one encoding when its cwd went through a symlink
  (`account-1` → `claude-3-hamagan-com`).
- A Claude window reads its chat list only at start-up and may write its folder
  back when it quits. **Records are only touched while both the source and the
  destination window are not running.**

## Destinations

Every `(profile, accountUuid, orgUuid)` folder that exists under any profile's
`claude-code-sessions/`, minus the chat's own. Labelled
`<profile number/name> · <account label> · <org name>`.

Config gains `orgNames: [orgUuid: String]` and `accountNames: [accountUuid: String]`,
pre-filled on first run with the known ones (`793c813a…` Hamagan Technologies,
`eb9c2554…` lajward.dev Personal; `8487574e…` rashid@hamagan.com,
`f1d3cc98…` rashid@lajward.dev). Unknown ids show their first 8 characters.

## Pending moves

Picking a destination creates a `PendingMove`
`{id, sessionId, cliSessionId, title, from: {profileId, accountUuid, orgUuid}, to: {…}, createdAt, status, note}`
with status `pending → done | failed | conflict | undone`. Stored with history
(last 200) in `~/Library/Application Support/claude-watch/moves.json`.

A pending move runs as soon as a poll sees neither its source nor its
destination window running. After picking a destination the app asks:

> Move "<title>" to <dest>? Windows <src> and <dest> need to restart.
> [Restart now] [Later]

- **Restart now** — if a chat in those windows is working, confirm first
  ("Window 3 has 2 chats working. Quit anyway?"). Quit each window gracefully
  (`NSRunningApplication.terminate()`), wait up to 20 s, run every due move,
  reopen each window through its launcher (`DesktopLink.ensureRunning`).
  A window that does not quit leaves the move pending and posts a notification.
- **Later** — the chat row shows `→ <dest> · waiting for restart`; the move runs
  on the first poll where both windows are closed and posts
  "Moved “<title>” to <dest>."

## Executing one move

1. **Checks** — source record exists; destination has no `local_<id>.json`
   (else `conflict`, nothing written); chat not working in a live CLI process.
2. **Backup** — copy the source record, plus the source `archived-sessions.idx`,
   to `claude-watch/moves/<timestamp>-<id>/` with `move.json` describing it.
3. **Rewrite** the record for the destination:
   - drop account-specific keys: `remoteMcpServersConfig`,
     `sessionPermissionUpdates`, `alwaysAllowedReasons`, `toolSurfaceSnapshot`;
   - if `cwd` is a scratch workspace
     (`<srcProfile>/scratch-workspaces/<srcAccount>/<srcOrg>/<name>`, compared
     after resolving symlinks), move that folder to
     `<dstProfile>/scratch-workspaces/<dstAccount>/<dstOrg>/<name>`, set `cwd`
     and `originCwd` to the new path, and move every
     `~/.claude/projects/<encoding of old path>/<cliSessionId>{.jsonl,/}` to the
     new path's encoding (all encodings of the old path: as written, and resolved);
   - project folders elsewhere (e.g. `~/Development/…`) are left alone.
4. **Write** the record to `<dstProfile>/claude-code-sessions/<dstAccount>/<dstOrg>/`;
   if it was archived, add it to that folder's `archived-sessions.idx`.
5. **Remove** the source record and its entry in the source `archived-sessions.idx`.
6. **Log** the result in `moves.json`.

Any failure in 3–5 rolls back: moved folders go back, the written destination
record is deleted, the source record and index are restored from the backup.
The move is marked `failed` with the error.

**Undo** creates a new pending move in the opposite direction (same rules).

## UI

- **Chat rows (popover):** on hover a `⇄` button opens a destination menu.
  Disabled with a reason tooltip when the chat is working, needs you, or already
  has a pending move. A pending chat shows `→ <dest> · waiting for restart`.
- **Account card:** an `All chats…` link opens the chats window on that account.
- **All chats window:** account picker, search over title and folder, "include
  archived" toggle; rows with title, folder, last active, `Move to ▾`;
  multi-select to move several; a Recent moves list with Undo.

## CLI

- `claude-watch move <local_id | title fragment> --to <profileId>[:<orgUuid-prefix>]`
  (`--now` to restart windows without asking).
- `claude-watch moves` — pending + history; `claude-watch moves --undo <moveId>`.

## Code layout

- `WatchCore/SessionMover.swift` — destinations, plan, checks, execute,
  rollback. Takes root URLs (profiles, claude home, support) so tests run on a
  temporary tree.
- `WatchCore/Moves.swift` — `PendingMove`, `moves.json` store, due-check
  called from `Monitor.poll()`.
- `WatchCore/WindowControl.swift` — quit / wait / relaunch windows.
- `ClaudeWatch/App.swift` — row button, pending label, prompt, link.
- `ClaudeWatch/ChatsWindow.swift` — the All chats window.
- `claude-watch/main.swift` — `move`, `moves`.

## Testing

Unit tests on a temporary tree: plain move; scratch-folder move with two
transcript encodings; archived chat; conflict; rollback after an injected
failure; undo; due-check waits while a window runs. Then one real move of a
throwaway chat between two profiles.
