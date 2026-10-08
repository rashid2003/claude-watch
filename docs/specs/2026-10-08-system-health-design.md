# Session Watch system health — design

**Date:** 2026-10-08 · **Status:** agreed

## Goal

See the Mac's resource usage on the iPhone and in the Mac app, get warned before the Mac runs out of memory, disk, CPU or cooling, and act from the phone: quit heavy apps, force-kill a process, close idle Claude profiles, or free disk space. Optionally, Session Watch acts on its own when things get critical.

Background: earlier crashes (watchdog timeouts) came from a nearly full disk (7 GB free), swap at 9.6/10 GB and a load average of 46 on 10 cores. The usual culprits were the Android emulator, the Docker VM, stray Python processes and several Claude desktop profiles.

## 1. Sampler (Mac, `WatchCore`)

`SystemSampler` takes a reading every 5 s on a background queue, using native calls only (no child processes):

| Field | Source |
|---|---|
| `pressure` (normal / warn / critical) | `sysctl kern.memorystatus_vm_pressure_level` (1 / 2 / 4) |
| `memTotal`, `memUsed`, `memCompressed` | `hw.memsize` and `host_statistics64(HOST_VM_INFO64)`: used = (active + wired + compressor) pages × page size |
| `swapUsed`, `swapTotal` | `sysctl vm.swapusage` |
| `load1`, `load5`, `cores` | `getloadavg`, `ProcessInfo.activeProcessorCount` |
| `thermal` | `ProcessInfo.thermalState` |
| `diskFree`, `diskTotal` | `/` volume, `volumeAvailableCapacityForImportantUsage` and `volumeTotalCapacity` |

**History.** A ring buffer of 360 points (30 min at 5 s) holding `at, memUsed, swapUsed, load1, diskFree`, for the trend lines.

**Top apps** (`TopProcesses`). Every 5 s it enumerates the user's processes (`proc_listallpids`, `proc_pidpath`, `proc_pid_rusage` with `RUSAGE_INFO_V4`):

- `rss` is the physical footprint (`ri_phys_footprint`).
- `cpu` % is the change in `ri_user_time + ri_system_time` between two samples ÷ wall time.

Processes are grouped:

- A process whose path contains `/<Name>.app/` belongs to the **outermost** `.app` in that path. Chrome Helper and Claude Helper therefore fold into their apps, and a Docker VM process under `Docker.app` folds into Docker.
- Each `.app` gets one `AppUsage` row with `id = bundle path`, the summed memory and CPU, the process count, the main pid (lowest pid, or the pid of a matching `NSRunningApplication` if there is one), and `canQuit` = whether an `NSRunningApplication` exists for it.
- Processes outside any `.app` (`qemu-system-*`, `python3`, `node`) get one row each, with `id = "pid:<pid>"` and `canQuit = false`.
- Each Claude desktop profile instance is its own app row, labelled with its profile name, by matching the main pid against the profile pids that `ProcessTree` already finds.

The list sent out has the top 12 rows by memory and the top 12 by CPU, merged without duplicates. Each row has `name`, `rss`, `cpu`, `processes`, `pids` (up to 20, largest first), `canQuit` and `canKill`. `canKill` is false for:

- pid ≤ 1
- processes owned by another user (`kp_eproc.e_ucred.cr_uid != getuid()`)
- the protected names `launchd`, `WindowServer`, `kernel_task`, `loginwindow`, `Dock`, `Finder`, `SystemUIServer`, `ControlCenter`
- Session Watch's own pid

## 2. Risk rules (`HealthRules`, pure)

| Signal | Warn | Critical | Reason text |
|---|---|---|---|
| Memory pressure | warn | critical | "memory pressure critical" |
| Swap | used/total > 75% (and total ≥ 1 GB) | > 90% | "swap 9.6/10 GB" |
| Disk free | < `diskWarnGB` (50) | < `diskCriticalGB` (20) | "disk 7 GB free" |
| CPU | load5 ÷ cores > 2 | > 4 | "load 46 on 10 cores" |
| Thermal | serious | critical | "thermal serious" |

- The overall `level` is the worst signal: `ok` < `warn` < `critical`.
- `reasons` lists the non-ok signals, worst first.
- Thresholds live in `Config.system` (see §5); defaults as above.

## 3. Alerts (`HealthAlerter`, pure state machine fed one reading at a time)

- A level must hold for 60 s before it counts. This is the "confirmed level".
- A push is sent when the confirmed level rises: ok → warn, ok → critical or warn → critical.
- After an alert, no new alert at the same level until the confirmed level has been `ok` for 30 min. An escalation always alerts.
- Push text, for example:
  - title: "Mac memory critical"
  - body: "swap 9.6/10 GB · disk 18 GB free — Docker 6.1 GB, qemu 1.9 GB"
  - it names the top 2 apps by memory
- New `NotifyEvent.system`. It is on by default for every device, and the existing notification switches in the iPhone app control it.
- The Mac app also posts a local macOS notification with the same text, so the Mac user sees it without the phone.

## 4. Actions

All actions go through the existing `BridgeCommand` → job → audit path, so they're logged and safe to send twice.

| Route | Command | Behaviour |
|---|---|---|
| `POST /v1/system/apps/quit` `{appId}` | `.quitApp` | `NSRunningApplication.terminate()` for every running app whose bundle URL is `appId`. Fails if there's no such app. Job is done once it has exited (10 s wait), or failed with "still running (it may be asking to save)". |
| `POST /v1/system/processes/kill` `{pid}` | `.killProcess` | Re-check the `canKill` rules against the live process, then `kill(pid, SIGKILL)`. |
| `POST /v1/system/claude/close-idle` | `.closeIdleClaude` | Profiles with a running desktop app and no working chat (same test as the CLI `moves --now`) → `WindowControl.quit`. Reports which profiles were quit and which were skipped as busy. |
| `POST /v1/system/disk/clean` `{targets:[id]}` | `.cleanDisk` | Runs the chosen targets one after another and reports the bytes freed. |

**Clean targets** (`DiskCleaner`). Sizes are measured in the background every 10 min and on demand, and are sent in `SystemHealth.cleanable`:

| id | What | How |
|---|---|---|
| `trash` | `~/.Trash` | Remove its contents (Finder's "Empty Trash" equivalent for the user's own Trash) |
| `derivedData` | `~/Library/Developer/Xcode/DerivedData` | Remove its contents |
| `simulators` | Unavailable simulators | `xcrun simctl delete unavailable` (size = sum of those device dirs) |
| `npm` | `~/.npm/_cacache` | Remove the directory |
| `brew` | Homebrew cache | `brew cleanup -s` when brew exists (size = `~/Library/Caches/Homebrew`) |

Targets that don't exist or are 0 bytes are left out of the list.

The phone confirms every action. Kill and clean use a destructive (red) confirmation that names what will happen, such as "Kill qemu-system-aarch64 (pid 4411)? Unsaved work is lost." or "Permanently delete 14.2 GB?".

## 5. Auto-act (opt-in, Settings)

`Config.system.auto` holds:

- `enabled: Bool` (default **false**)
- `afterSeconds: Int` (default 120): how long the confirmed level must stay `critical` before acting
- `quitApps: [String]`: bundle paths or process names the user picked from the current top list, such as Docker, the Android emulator (`qemu-system-*`), or Simulator
- `forceIfStuck: Bool` (default false): SIGKILL an app that is still running 30 s after the polite quit
- `closeIdleClaude: Bool` (default false)
- `cleanTargets: [String]` (default `[]`): only acted on when **disk** is the critical signal; `trash` is not allowed here

When `enabled` and the confirmed level has been critical for `afterSeconds`:

1. Run the configured actions once, in order: close idle Claude → quit listed apps (all instances) → clean targets (only if disk is critical).
2. They run through the same job/audit path, with device name "auto".
3. Push and post locally: "Session Watch freed memory: quit Docker, Android Emulator" (`NotifyEvent.system`).
4. It won't act again until the confirmed level has dropped below critical and returned.

**Settings UI.**

- The **Mac Settings** window gets a "System" tab with:
  - the auto-act switch
  - the delay
  - the app list, picked from the current top apps plus anything already listed, with remove buttons
  - the two switches and the clean-target checkboxes
  - the disk thresholds
- The **iPhone** system section shows "auto-act on · quits Docker, qemu after 2 min critical" and has a switch for `enabled` only: `POST /v1/system/auto {enabled}` → `.setAutoAct`. The full list is edited on the Mac.

## 6. Wire

New `WatchProtocol/SystemHealth.swift`:

```swift
public enum HealthLevel: String, Codable { case ok, warn, critical }
public struct HealthPoint: Codable { at: Date; memUsed, swapUsed, diskFree: Int64; load1: Double }
public struct AppUsage: Codable, Identifiable { id, name: String; rss: Int64; cpu: Double; processes: Int; pids: [Int32]; canQuit, canKill: Bool }
public struct CleanTarget: Codable, Identifiable { id, label: String; bytes: Int64 }
public struct AutoActSummary: Codable { enabled: Bool; afterSeconds: Int; quitApps: [String]; closeIdleClaude: Bool; cleanTargets: [String] }
public struct SystemHealth: Codable {
  at: Date; level: HealthLevel; reasons: [String]
  pressure: HealthLevel; memTotal, memUsed, memCompressed, swapUsed, swapTotal, diskFree, diskTotal: Int64
  load1, load5: Double; cores: Int; thermal: String   // nominal|fair|serious|critical
  apps: [AppUsage]; cleanable: [CleanTarget]; history: [HealthPoint]; auto: AutoActSummary
}
```

- `GET /v1/system` returns `SystemHealth` with the full history. 503 until the first reading.
- WebSocket: `WSClientMessage.Kind` gains `watchSystem` and `unwatchSystem`.
  - While watching, the Mac sends `WSServerMessage.system(SystemHealth)` every 5 s with `history` holding only the newest point. The phone appends it.
  - The first message after `watchSystem` carries the full history.
- `Snapshot` gains `systemLevel: HealthLevel?` (decodeIfPresent) so the phone can show a dot on the Mac tab without watching.

## 7. UI

**iPhone (`Views/SystemSection.swift`, at the top of the Mac tab).** It sends `watchSystem` while visible and `unwatchSystem` when it disappears or the app goes to the background.

- A level banner (ok / warn / critical colour) with the reasons.
- Four rows of a label, value and 30-min sparkline:
  - memory: used/total plus pressure
  - swap: used/total
  - CPU: load ÷ cores
  - disk: free/total
- "top apps": rows of name, memory, CPU and process count.
  - The context menu and swipe actions offer **Quit** (if `canQuit`) and **Kill** (if `canKill`; for multi-process apps it kills the main pid).
- Buttons:
  - **close idle Claude**
  - **free disk…**, a sheet listing the clean targets with sizes and checkboxes, then a red confirm
- The auto-act line and its switch.
- The Mac tab in the bottom bar shows a warn/critical dot from `snapshot.systemLevel`.

**Mac (`ClaudeWatch/SystemPanel.swift`).** The same content as a section in the main window, with the same actions run directly (not over HTTP) through the same `BridgeHandler.perform` code.

## 8. Code layout

| File | Contents |
|---|---|
| `Sources/WatchProtocol/SystemHealth.swift` | Models |
| `Sources/WatchCore/SystemSampler.swift` | Readings and history |
| `Sources/WatchCore/TopProcesses.swift` | Enumeration, grouping, kill guard |
| `Sources/WatchCore/HealthRules.swift` | Levels, reasons, `HealthAlerter`, auto-act trigger |
| `Sources/WatchCore/DiskCleaner.swift` | Sizing and cleaning |
| `Sources/WatchCore/SystemActions.swift` | Quit, kill, close-idle-Claude |
| `Sources/WatchCore/Config.swift` | Adds `SystemConfig` |
| `Sources/WatchBridge/Server.swift` | New routes and commands; WS watch |
| `Sources/ClaudeWatch/BridgeController.swift` | Runs the sampler, alerts, auto-act and perform |
| `Sources/ClaudeWatch/SystemPanel.swift` | Main window section |
| `Sources/ClaudeWatch/SettingsView.swift` | System tab |
| `iOS/ClaudeRemote/Views/SystemSection.swift` | iPhone section |
| `iOS/ClaudeRemote/RemoteStore.swift`, `RemoteCommand.swift` | Watching, commands |

## 9. Testing

- **Unit:**
  - `HealthRules` thresholds and reasons
  - `HealthAlerter`: 60 s hold, escalation, 30 min re-arm, auto-act fires once
  - grouping by outermost `.app`
  - the `canKill` guard
  - `SystemHealth` and `WSServerMessage.system` round trips
  - `Snapshot` decoding without `systemLevel`
  - server routing for the four commands and auto
  - `DiskCleaner` sizing and cleaning in a temp directory
- **Smoke:** `SystemSampler` on this Mac gives memTotal > 0, cores > 0, diskTotal > diskFree > 0, and a non-empty app list.
- **Manual:** run the Mac app and the iPhone simulator, check the section renders and updates, and quit a test app (TextEdit) from the phone.
