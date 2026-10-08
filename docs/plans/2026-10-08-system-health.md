# System Health Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:**

- The Mac samples memory, swap, CPU, thermal and disk every 5 s, rates them ok, warn or critical, and alerts the paired iPhone.
- From the phone or the Mac you can quit or kill heavy apps, close idle Claude profiles and free disk space.
- Optionally, it acts on its own when things stay critical.

**Architecture:**

- `WatchCore` holds the pure parts (rules, alerter, grouping, kill guard) and the probes (`SystemProbe`, `ProcessScan`, `DiskCleaner`, `SystemActions`).
- `SystemWatch` (WatchCore) runs the 5 s timer. `WatchModel` owns it and feeds `BridgeController`.
- The bridge adds `GET /v1/system`, WebSocket `watchSystem` streaming, five commands and the `system` push event.
- The iPhone gets a system section at the top of the Mac tab. The Mac gets a "system" sidebar section and a Settings section.

**Tech stack:** Swift 5.10 SwiftPM (macOS 14), SwiftUI, Darwin `sysctl`/`proc_*`/`host_statistics64`, XCTest. iOS uses Xcode 16 synchronized groups, so new files are picked up automatically.

Spec: `docs/specs/2026-10-08-system-health-design.md`.

---

## File map

| File | Responsibility |
|---|---|
| `Sources/WatchProtocol/SystemHealth.swift` (new) | `HealthLevel`, `HealthPoint`, `AppUsage`, `CleanTarget`, `AutoActSummary`, `SystemHealth`, command bodies |
| `Sources/WatchProtocol/Wire.swift` | `NotifyEvent.system`; WS `watchSystem`/`unwatchSystem`; `WSServerMessage.system` |
| `Sources/WatchProtocol/Models.swift` | `Snapshot.systemLevel` |
| `Sources/WatchCore/Config.swift` | `SystemConfig`, `AutoActConfig` |
| `Sources/WatchCore/HealthRules.swift` (new) | `HealthRules.evaluate`, `HealthAlerter` |
| `Sources/WatchCore/SystemProbe.swift` (new) | Raw readings: pressure, memory, swap, load, thermal, disk |
| `Sources/WatchCore/ProcessScan.swift` (new) | Process enumeration, CPU deltas, `AppGrouper`, `KillGuard` |
| `Sources/WatchCore/DiskCleaner.swift` (new) | Measures and cleans the targets |
| `Sources/WatchCore/SystemActions.swift` (new) | Quit, kill, close idle Claude, clean (shared by the bridge, the Mac UI and auto-act) |
| `Sources/WatchCore/SystemWatch.swift` (new) | Timer, history ring, alerter, auto-act trigger, callbacks |
| `Sources/WatchBridge/Server.swift` | Commands, routes, WS watch, `publish(system:)` |
| `Sources/ClaudeWatch/BridgeController.swift` | check/run for the system commands, system push, `systemHealth()` |
| `Sources/ClaudeWatch/App.swift` | `MainSection.system`, owns `SystemWatch`, local notifications, auto-act |
| `Sources/ClaudeWatch/SystemPanel.swift` (new) | Mac section UI |
| `Sources/ClaudeWatch/MainWindow.swift` | Route `.system` |
| `Sources/ClaudeWatch/SettingsView.swift` | "system" settings section |
| `iOS/ClaudeRemote/RemoteStore.swift` | `system` state, watch/unwatch, `.system` handling |
| `iOS/ClaudeRemote/RemoteCommand.swift` | Five commands and keys |
| `iOS/ClaudeRemote/Views/SystemSection.swift` (new) | iPhone section UI |
| `iOS/ClaudeRemote/Views/MacView.swift` | Embed the section; notify title for `.system` |
| `iOS/ClaudeRemote/Views/BottomBar.swift` | Mac tab dot from `snapshot.systemLevel` |
| `iOS/ClaudeRemote/Fixtures.swift` | `Fixtures.system` for demo and previews |
| Tests | `Tests/WatchProtocolTests/SystemWireTests.swift`, `Tests/WatchCoreTests/HealthRulesTests.swift`, `Tests/WatchCoreTests/ProcessScanTests.swift`, `Tests/WatchCoreTests/DiskCleanerTests.swift`, `Tests/WatchCoreTests/SystemProbeTests.swift`, plus additions to `Tests/WatchBridgeTests/ServerTests.swift` |

Run all tests with `swift test` from the worktree root (`~/Development/claude-watch-system-health`).

---

### Task 1: Protocol models

**Files:**
- Create `Sources/WatchProtocol/SystemHealth.swift`.
- Modify `Sources/WatchProtocol/Wire.swift` and `Sources/WatchProtocol/Models.swift`.
- Test: `Tests/WatchProtocolTests/SystemWireTests.swift`.

- [ ] **Step 1: Write the failing tests.**

```swift
import XCTest
@testable import WatchProtocol

final class SystemWireTests: XCTestCase {
    static func sample(history: Int = 3) -> SystemHealth {
        SystemHealth(at: Date(timeIntervalSince1970: 1_790_600_000), level: .warn, reasons: ["swap 8/10 GB"],
                     pressure: .ok, memTotal: 32 << 30, memUsed: 20 << 30, memCompressed: 3 << 30,
                     swapUsed: 8 << 30, swapTotal: 10 << 30, diskFree: 80 << 30, diskTotal: 994 << 30,
                     load1: 6, load5: 5, cores: 10, thermal: "nominal",
                     apps: [AppUsage(id: "/Applications/Docker.app", name: "Docker", rss: 6 << 30, cpu: 40, processes: 7,
                                     pids: [501, 502], mainPid: 501, canQuit: true, canKill: true)],
                     cleanable: [CleanTarget(id: "derivedData", label: "Xcode DerivedData", bytes: 14 << 30)],
                     history: (0..<history).map { HealthPoint(at: Date(timeIntervalSince1970: Double(1_790_600_000 + $0 * 5)),
                                                             memUsed: 1, swapUsed: 2, diskFree: 3, load1: 4) },
                     auto: AutoActSummary(enabled: false, afterSeconds: 120, quitApps: [], closeIdleClaude: false, cleanTargets: []))
    }

    func testSystemHealthRoundTrip() throws {
        let h = Self.sample()
        let back = try WireCoder.decoder.decode(SystemHealth.self, from: WireCoder.encoder.encode(h))
        XCTAssertEqual(back, h)
        XCTAssertEqual(h.latestOnly.history.count, 1)
        XCTAssertEqual(h.latestOnly.history.first, h.history.last)
    }

    func testLevelOrdering() {
        XCTAssertLessThan(HealthLevel.ok, .warn)
        XCTAssertLessThan(HealthLevel.warn, .critical)
        XCTAssertEqual([HealthLevel.warn, .critical, .ok].max(), .critical)
    }

    func testServerMessageAndClientKinds() throws {
        let m = WSServerMessage.system(Self.sample(history: 1))
        let back = try WireCoder.decoder.decode(WSServerMessage.self, from: WireCoder.encoder.encode(m))
        guard case .system(let h) = back else { return XCTFail("wrong case") }
        XCTAssertEqual(h.apps.first?.name, "Docker")
        let c = try WireCoder.decoder.decode(WSClientMessage.self, from: Data(#"{"type":"watchSystem"}"#.utf8))
        XCTAssertEqual(c.type, .watchSystem)
    }

    func testSnapshotWithoutSystemLevelDecodes() throws {
        let json = #"{"at":1790600000,"accounts":[],"queue":[],"engineOwner":true,"scanning":false}"#
        let s = try WireCoder.decoder.decode(Snapshot.self, from: Data(json.utf8))
        XCTAssertNil(s.systemLevel)
        var t = s; t.systemLevel = .critical
        XCTAssertEqual(try WireCoder.decoder.decode(Snapshot.self, from: WireCoder.encoder.encode(t)).systemLevel, .critical)
    }
}
```

- [ ] **Step 2: Run the tests and check they fail.** Run `swift test --filter SystemWireTests`. Expected: compile errors (`SystemHealth` undefined).

- [ ] **Step 3: Implement.**

`SystemHealth.swift` holds:

- `HealthLevel`: `String`, `Codable`, `Sendable`, `Comparable`, `CaseIterable`, cases `ok`, `warn`, `critical`, and a `rank`.
- `HealthPoint`, `AppUsage` (as in the test, including `mainPid`), `CleanTarget`, `AutoActSummary`.
- `SystemHealth` with all fields as in the test, `Equatable`, plus `var latestOnly: SystemHealth` (history trimmed to its last element).
- Command bodies, each with `requestId: String = UUID().uuidString`:
  - `QuitAppBody { appId: String }`
  - `KillBody { pid: Int32 }`
  - `CleanBody { targets: [String] }`
  - `AutoActBody { enabled: Bool }`

`Wire.swift` changes:

- `NotifyEvent` gains `system`.
- `WSClientMessage.Kind` gains `watchSystem` and `unwatchSystem`.
- `WSServerMessage` gains `case system(SystemHealth)` with coding key `system`, type `"system"`.

`Models.swift` changes:

- `Snapshot` gains `public var systemLevel: HealthLevel? = nil`.
- Add it to `CodingKeys`, `init(from:)` (decodeIfPresent) and the memberwise init (default nil).

- [ ] **Step 4: Run the tests and check they pass.** Run `swift test --filter SystemWireTests`. Expected: 4 tests pass. Then run `swift build`; any `switch` over `NotifyEvent` or `WSServerMessage` in macOS targets must still compile (the bridge's `onFrame` switch gets the new kinds in Task 7; add `case .watchSystem, .unwatchSystem: break` there now if the build needs it).

- [ ] **Step 5: Commit.** Message: "Add system health models to the wire protocol".

### Task 2: Config

**Files:**
- Modify `Sources/WatchCore/Config.swift`.
- Test: `Tests/WatchCoreTests/ConfigTests.swift` (append).

- [ ] **Step 1: Write the failing test.**

```swift
func testSystemConfigDefaultsAndPartialDecode() throws {
    let empty = try JSONCoder.decoder.decode(Config.self, from: Data("{}".utf8))
    XCTAssertEqual(empty.system.diskWarnGB, 50)
    XCTAssertEqual(empty.system.diskCriticalGB, 20)
    XCTAssertFalse(empty.system.auto.enabled)
    XCTAssertEqual(empty.system.auto.afterSeconds, 120)
    let partial = try JSONCoder.decoder.decode(Config.self, from: Data(#"{"system":{"auto":{"enabled":true,"quitApps":["qemu-system-aarch64"]}}}"#.utf8))
    XCTAssertTrue(partial.system.auto.enabled)
    XCTAssertEqual(partial.system.auto.quitApps, ["qemu-system-aarch64"])
    XCTAssertEqual(partial.system.diskWarnGB, 50)
    XCTAssertEqual(partial.system.auto.afterSeconds, 120)
}
```

- [ ] **Step 2: Run it and check it fails.** Run `swift test --filter ConfigTests`.

- [ ] **Step 3: Implement.**

```swift
public struct AutoActConfig: Codable, Sendable, Equatable {
    public var enabled = false
    public var afterSeconds = 120
    public var quitApps: [String] = []        // AppUsage.id (bundle path) or a process name
    public var forceIfStuck = false
    public var closeIdleClaude = false
    public var cleanTargets: [String] = []    // never "trash"
    public init() {}
    public init(from decoder: Decoder) throws { /* decodeIfPresent each, defaulting to Self() values; drop "trash" from cleanTargets */ }
    public var summary: AutoActSummary { AutoActSummary(enabled: enabled, afterSeconds: afterSeconds, quitApps: quitApps,
                                                        closeIdleClaude: closeIdleClaude, cleanTargets: cleanTargets) }
}
public struct SystemConfig: Codable, Sendable, Equatable {
    public var diskWarnGB: Double = 50
    public var diskCriticalGB: Double = 20
    public var auto = AutoActConfig()
    public init() {}
    public init(from decoder: Decoder) throws { /* decodeIfPresent with defaults */ }
}
```

Add `public var system = SystemConfig()` to `Config`, and `system = try c.decodeIfPresent(SystemConfig.self, forKey: .system) ?? d.system` to its decoder. Write the `init(from:)` bodies out in full, in the same style as `Config`.

- [ ] **Step 4: Run it and check it passes.**
- [ ] **Step 5: Commit.** Message: "Add system health settings to the config".

### Task 3: Risk rules and alerter

**Files:**
- Create `Sources/WatchCore/HealthRules.swift`.
- Test: `Tests/WatchCoreTests/HealthRulesTests.swift`.

Interfaces:

```swift
public struct HealthInputs: Sendable {
    public var pressure: HealthLevel; public var swapUsed, swapTotal, diskFree: Int64
    public var load5: Double; public var cores: Int; public var thermal: ProcessInfo.ThermalState
}
public enum HealthRules {
    /// Worst level plus non-ok reasons, worst first.
    public static func evaluate(_ i: HealthInputs, _ cfg: SystemConfig) -> (level: HealthLevel, reasons: [String])
    public static func thermalName(_ t: ProcessInfo.ThermalState) -> String   // nominal|fair|serious|critical
}
public struct HealthAlerter: Sendable {
    public static let hold: TimeInterval = 60, rearm: TimeInterval = 1800
    public private(set) var confirmed: HealthLevel = .ok
    public init()
    /// Feed one reading. Returns the level to alert about (if any) and whether auto-act should fire now.
    public mutating func feed(_ level: HealthLevel, at now: Date, autoEnabled: Bool, autoAfter: TimeInterval) -> (alert: HealthLevel?, autoAct: Bool)
}
```

Rules:

| Signal | Warn | Critical | Reason text |
|---|---|---|---|
| Swap (only when total ≥ 1 GiB) | ratio > 0.75 | ratio > 0.90 | `swap 9.6/10 GB` (`Fmt` GB with one decimal, `/total` rounded) |
| Disk | free < warnGB | free < criticalGB | `disk 7 GB free` |
| Load | load5 / cores > 2 | > 4 | `load 46 on 10 cores` |
| Pressure | warn | critical | `memory pressure warn` / `memory pressure critical` |
| Thermal | serious | critical | `thermal serious` / `thermal critical` |

GB means 1e9 bytes (Finder style) for display and thresholds.

Alerter:

- `candidate` + `candidateSince`. When `now - candidateSince >= hold` and `candidate != confirmed`, set `confirmed = candidate` and `confirmedSince = now`.
- `lastAlerted: HealthLevel` (starts `.ok`). If `confirmed > lastAlerted`, alert `confirmed` and set `lastAlerted = confirmed`.
- If `confirmed < lastAlerted` holds continuously for `rearm`, set `lastAlerted = confirmed`. Track `belowSince`, reset whenever `confirmed >= lastAlerted`.
- Auto-act: `autoEnabled && confirmed == .critical && now - confirmedSince >= autoAfter && !autoFired` → fire and set `autoFired = true`. `autoFired` resets when `confirmed != .critical`.

- [ ] **Step 1: Write the failing tests.**

```swift
import XCTest
@testable import WatchCore
import WatchProtocol

final class HealthRulesTests: XCTestCase {
    let GB: Int64 = 1_000_000_000
    func inputs(pressure: HealthLevel = .ok, swap: (Int64, Int64) = (0, 0), disk: Int64 = 500, load5: Double = 1,
                thermal: ProcessInfo.ThermalState = .nominal) -> HealthInputs {
        HealthInputs(pressure: pressure, swapUsed: swap.0 * GB / 10, swapTotal: swap.1 * GB / 10, diskFree: disk * GB,
                     load5: load5, cores: 10, thermal: thermal)
    }

    func testAllOk() {
        let r = HealthRules.evaluate(inputs(), SystemConfig())
        XCTAssertEqual(r.level, .ok); XCTAssertEqual(r.reasons, [])
    }

    func testLastCrashLooksCritical() {
        let r = HealthRules.evaluate(inputs(swap: (96, 100), disk: 7, load5: 46), SystemConfig())
        XCTAssertEqual(r.level, .critical)
        XCTAssertEqual(r.reasons, ["swap 9.6/10 GB", "disk 7 GB free", "load 46 on 10 cores"])
    }

    func testWarnThresholds() {
        XCTAssertEqual(HealthRules.evaluate(inputs(swap: (80, 100)), SystemConfig()).level, .warn)
        XCTAssertEqual(HealthRules.evaluate(inputs(disk: 40), SystemConfig()).level, .warn)
        XCTAssertEqual(HealthRules.evaluate(inputs(load5: 25), SystemConfig()).level, .warn)
        XCTAssertEqual(HealthRules.evaluate(inputs(pressure: .warn), SystemConfig()).level, .warn)
        XCTAssertEqual(HealthRules.evaluate(inputs(thermal: .serious), SystemConfig()).level, .warn)
        XCTAssertEqual(HealthRules.evaluate(inputs(thermal: .critical), SystemConfig()).level, .critical)
        XCTAssertEqual(HealthRules.evaluate(inputs(swap: (5, 8)), SystemConfig()).level, .ok, "under 1 GB of swap is ignored")
        var cfg = SystemConfig(); cfg.diskWarnGB = 30
        XCTAssertEqual(HealthRules.evaluate(inputs(disk: 40), cfg).level, .ok)
    }

    func testCriticalReasonsComeFirst() {
        let r = HealthRules.evaluate(inputs(swap: (80, 100), disk: 10), SystemConfig())
        XCTAssertEqual(r.reasons.first, "disk 10 GB free")
    }

    func testAlerterHoldsEscalatesAndRearms() {
        var a = HealthAlerter()
        let t0 = Date(timeIntervalSince1970: 0)
        func feed(_ l: HealthLevel, _ s: Double) -> HealthLevel? { a.feed(l, at: t0 + s, autoEnabled: false, autoAfter: 120).alert }
        XCTAssertNil(feed(.warn, 0))
        XCTAssertNil(feed(.warn, 30), "not held long enough")
        XCTAssertEqual(feed(.warn, 60), .warn)
        XCTAssertNil(feed(.warn, 65), "alerts once")
        XCTAssertNil(feed(.critical, 70))
        XCTAssertEqual(feed(.critical, 130), .critical, "escalation alerts")
        XCTAssertNil(feed(.ok, 140)); XCTAssertNil(feed(.ok, 200))
        XCTAssertNil(feed(.critical, 300)); XCTAssertNil(feed(.critical, 360), "same level within re-arm window")
        XCTAssertNil(feed(.ok, 400)); XCTAssertNil(feed(.ok, 460))
        XCTAssertNil(feed(.ok, 460 + 1800))
        XCTAssertNil(feed(.warn, 2400)); XCTAssertEqual(feed(.warn, 2460), .warn, "re-armed after 30 min below")
    }

    func testAutoActFiresOnceAfterDelay() {
        var a = HealthAlerter()
        let t0 = Date(timeIntervalSince1970: 0)
        func auto(_ l: HealthLevel, _ s: Double, on: Bool = true) -> Bool { a.feed(l, at: t0 + s, autoEnabled: on, autoAfter: 120).autoAct }
        XCTAssertFalse(auto(.critical, 0)); XCTAssertFalse(auto(.critical, 60))   // confirmed at 60
        XCTAssertFalse(auto(.critical, 170))
        XCTAssertTrue(auto(.critical, 180))
        XCTAssertFalse(auto(.critical, 400), "once per critical episode")
        XCTAssertFalse(auto(.warn, 410)); XCTAssertFalse(auto(.warn, 470))      // confirmed warn → re-arms auto
        XCTAssertFalse(auto(.critical, 500)); XCTAssertFalse(auto(.critical, 560))
        XCTAssertTrue(auto(.critical, 680))
        var b = HealthAlerter()
        XCTAssertFalse(b.feed(.critical, at: t0, autoEnabled: false, autoAfter: 0).autoAct)
        XCTAssertFalse(b.feed(.critical, at: t0 + 600, autoEnabled: false, autoAfter: 0).autoAct, "disabled")
    }
}
```

- [ ] **Step 2: Run them and check they fail.** Run `swift test --filter HealthRulesTests`.
- [ ] **Step 3: Implement `HealthRules.swift`** following the rules above. Sort reasons by severity (critical first) and then by the table order: swap, disk, load, pressure, thermal. Format numbers with `String(format:)`: swap used uses one decimal; swap total, disk and load are rounded integers.
- [ ] **Step 4: Run them and check they pass.**
- [ ] **Step 5: Commit.** Message: "Rate system health and decide when to alert".

### Task 4: Probes and process grouping

**Files:**
- Create `Sources/WatchCore/SystemProbe.swift` and `Sources/WatchCore/ProcessScan.swift`.
- Tests: `Tests/WatchCoreTests/ProcessScanTests.swift` and `Tests/WatchCoreTests/SystemProbeTests.swift`.

`SystemProbe` (an enum of static funcs):

- `pressure() -> HealthLevel`: `sysctlbyname("kern.memorystatus_vm_pressure_level")`. 4 → critical, 2 → warn, else ok.
- `memory() -> (total, used, compressed: Int64)`: `hw.memsize`. `host_statistics64(mach_host_self(), HOST_VM_INFO64, …)`: used = (active + wire + compressor_page_count) × `vm_kernel_page_size`, compressed = compressor_page_count × page.
- `swap() -> (used, total: Int64)`: `vm.swapusage` into `xsw_usage`.
- `load() -> (one, five: Double)`: `getloadavg`.
- `disk() -> (free, total: Int64)`: `URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])`.

`ProcessScan`:

```swift
public struct ProcSample: Sendable { public var pid: Int32; public var name: String; public var path: String; public var footprint: Int64; public var cpuNanos: UInt64 }
public final class ProcessScan {
    public init()
    /// The user's processes with CPU % since the previous call (0 on the first call for a pid).
    public func sample() -> [(ProcSample, cpu: Double)]
}
public enum AppGrouper {
    /// Outermost "/X.app" prefix of an executable path, or nil.
    public static func bundle(of path: String) -> String?
    /// Groups by outermost .app (else one row per process), sums, sorts; top `limit` by memory ∪ top `limit` by CPU.
    public static func group(_ procs: [(ProcSample, cpu: Double)], appPid: (String) -> Int32?, appName: (String) -> String?,
                             claudeNames: [Int32: String], guardFn: (ProcSample) -> Bool, limit: Int = 12) -> [AppUsage]
}
public enum KillGuard {
    public static let protectedNames: Set<String> = ["launchd", "WindowServer", "kernel_task", "loginwindow", "Dock", "Finder", "SystemUIServer", "ControlCenter"]
    public static func allows(pid: Int32, name: String, ownerUid: uid_t, myUid: uid_t = getuid(), selfPid: Int32 = getpid()) -> Bool
    /// Live check against the running process (owner via sysctl KERN_PROC_PID, name via proc_name).
    public static func allowsLive(pid: Int32) -> (Bool, String)
}
```

Implementation notes:

- Enumerate the user's pids with `ProcessTree.all()`.
- For each pid:
  - `proc_pidpath` (fall back to `proc_name`)
  - `proc_pid_rusage(pid, RUSAGE_INFO_V4, …)` → `ri_phys_footprint`, and `ri_user_time + ri_system_time` converted to ns with `mach_timebase_info` (on Apple Silicon these are mach ticks)
- CPU % = Δns / Δwall-ns × 100. Keep the last `(cpuNanos, at)` per pid and prune pids that are gone.
- Group rows:
  - `.app` groups: `name` = `appName(bundle)` ?? the bundle's file name without `.app`; `mainPid` = `appPid(bundle)` ?? lowest pid in the group; `canQuit` = `appPid(bundle) != nil`; `canKill` = `guardFn(main)`; `pids` = up to 20 by footprint.
  - Claude instances: Claude desktop profiles run as separate copies of `Claude.app`. Group them by root: walk each pid up its ppid chain to the first ancestor whose pid is in `claudeNames`, and make each such root its own row named `"Claude · <profile>"` with id `"claude:<pid>"`.
  - Simplest working rule: a process belongs to the nearest ancestor (or itself) that is a key in `claudeNames`; those rows are made first and the rest grouped by bundle. This needs ppid, so `ProcSample` gains `ppid`.
  - Non-app rows: id `"pid:<pid>"`, `canQuit` false.

- [ ] **Step 1: Write the failing tests** (pure grouping and guard).

```swift
import XCTest
@testable import WatchCore

final class ProcessScanTests: XCTestCase {
    func p(_ pid: Int32, _ path: String, mb: Int64, ppid: Int32 = 1) -> (ProcSample, cpu: Double) {
        (ProcSample(pid: pid, ppid: ppid, name: (path as NSString).lastPathComponent, path: path, footprint: mb << 20, cpuNanos: 0), cpu: Double(pid % 7))
    }

    func testOutermostBundle() {
        XCTAssertEqual(AppGrouper.bundle(of: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"),
                       "/Applications/Google Chrome.app")
        XCTAssertEqual(AppGrouper.bundle(of: "/Applications/Docker.app/Contents/MacOS/com.docker.virtualization"), "/Applications/Docker.app")
        XCTAssertNil(AppGrouper.bundle(of: "/Users/r/Library/Android/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64"))
    }

    func testGroupsHelpersAndKeepsLooseProcesses() {
        let procs = [p(100, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", mb: 300),
                     p(101, "/Applications/Google Chrome.app/Contents/Frameworks/X.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper", mb: 700, ppid: 100),
                     p(200, "/Users/r/Library/Android/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64", mb: 1900),
                     p(300, "/usr/bin/true", mb: 1)]
        let rows = AppGrouper.group(procs, appPid: { $0.hasSuffix("Chrome.app") ? 100 : nil }, appName: { _ in nil },
                                    claudeNames: [:], guardFn: { _ in true }, limit: 2)
        XCTAssertEqual(rows.map(\.name), ["qemu-system-aarch64", "Google Chrome"])
        let chrome = rows[1]
        XCTAssertEqual(chrome.rss, 1000 << 20); XCTAssertEqual(chrome.processes, 2)
        XCTAssertEqual(chrome.mainPid, 100); XCTAssertTrue(chrome.canQuit); XCTAssertEqual(chrome.pids, [101, 100])
        XCTAssertEqual(rows[0].id, "pid:200"); XCTAssertFalse(rows[0].canQuit)
    }

    func testClaudeProfilesAreSeparateRows() {
        let claude = "/Applications/Claude.app/Contents/MacOS/Claude"
        let helper = "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper"
        let rows = AppGrouper.group([p(10, claude, mb: 200), p(11, helper, mb: 900, ppid: 10),
                                     p(20, claude, mb: 150), p(21, helper, mb: 400, ppid: 20)],
                                    appPid: { _ in 10 }, appName: { _ in "Claude" },
                                    claudeNames: [10: "Hamagan", 20: "Lajward"], guardFn: { _ in true })
        XCTAssertEqual(Set(rows.map(\.name)), ["Claude · Hamagan", "Claude · Lajward"])
        XCTAssertEqual(rows.first { $0.name == "Claude · Hamagan" }?.rss, 1100 << 20)
        XCTAssertEqual(rows.first { $0.name == "Claude · Lajward" }?.id, "claude:20")
    }

    func testKillGuard() {
        let me = getuid()
        XCTAssertTrue(KillGuard.allows(pid: 4411, name: "qemu-system-aarch64", ownerUid: me))
        XCTAssertFalse(KillGuard.allows(pid: 1, name: "launchd", ownerUid: 0))
        XCTAssertFalse(KillGuard.allows(pid: 400, name: "WindowServer", ownerUid: me))
        XCTAssertFalse(KillGuard.allows(pid: 500, name: "python3", ownerUid: me &+ 1))
        XCTAssertFalse(KillGuard.allows(pid: getpid(), name: "x", ownerUid: me))
    }
}
```

`SystemProbeTests` (smoke):

```swift
import XCTest
@testable import WatchCore

final class SystemProbeTests: XCTestCase {
    func testReadingsAreSane() {
        let m = SystemProbe.memory(); XCTAssertGreaterThan(m.total, 1 << 30); XCTAssertGreaterThan(m.used, 0); XCTAssertLessThanOrEqual(m.used, m.total)
        let d = SystemProbe.disk(); XCTAssertGreaterThan(d.total, d.free); XCTAssertGreaterThan(d.free, 0)
        XCTAssertGreaterThan(SystemProbe.load().five, 0)
        let s = SystemProbe.swap(); XCTAssertGreaterThanOrEqual(s.total, s.used)
        let scan = ProcessScan(); _ = scan.sample(); usleep(200_000)
        let procs = scan.sample()
        XCTAssertTrue(procs.contains { $0.0.pid == getpid() && $0.0.footprint > 0 })
    }
}
```

- [ ] **Step 2: Run them and check they fail.** Run `swift test --filter "ProcessScanTests|SystemProbeTests"`.
- [ ] **Step 3: Implement both files.**
- [ ] **Step 4: Run them and check they pass.**
- [ ] **Step 5: Commit.** Message: "Read memory, swap, load, disk and per-app usage".

### Task 5: Disk cleaner

**Files:**
- Create `Sources/WatchCore/DiskCleaner.swift`.
- Test: `Tests/WatchCoreTests/DiskCleanerTests.swift`.

```swift
public struct DiskCleaner: Sendable {
    public var home: URL
    public var run: @Sendable (String, [String]) -> (status: Int32, out: String)?     // Shell.run in production
    public init(home: URL = Paths.home, run: @escaping @Sendable (String, [String]) -> (status: Int32, out: String)? = { Shell.run($0, $1, timeout: 120) })
    public static let ids = ["trash", "derivedData", "simulators", "npm", "brew"]
    /// Measures each target; drops ones that are missing or empty. Trash that can't be read reports bytes = -1 (unknown).
    public func measure() -> [CleanTarget]
    /// Cleans the given ids in order; returns bytes freed (best effort: before − after) and errors.
    public func clean(_ ids: [String]) -> (freed: Int64, errors: [String])
    static func size(_ url: URL) -> Int64?    // totalFileAllocatedSize sum, nil when unreadable/missing
}
```

Targets:

| id | Label | Path | How it's cleaned |
|---|---|---|---|
| `trash` | Trash | `~/.Trash` | `run("/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty the trash"])` |
| `derivedData` | Xcode DerivedData | `~/Library/Developer/Xcode/DerivedData` | Remove each child |
| `simulators` | Unavailable simulators | — | Size: `run("/usr/bin/xcrun", ["simctl","list","devices","unavailable","-j"])`, parse `devices[*][*].udid`, sum `~/Library/Developer/CoreSimulator/Devices/<udid>`. Clean: `run("/usr/bin/xcrun", ["simctl","delete","unavailable"])` |
| `npm` | npm cache | `~/.npm/_cacache` | Remove the directory |
| `brew` | Homebrew cache | `~/Library/Caches/Homebrew` | Only if `/opt/homebrew/bin/brew` or `/usr/local/bin/brew` exists: `run(brew, ["cleanup","-s"])` |

- [ ] **Step 1: Write the failing tests** (a temp home with a fake run).

```swift
import XCTest
@testable import WatchCore

final class DiskCleanerTests: XCTestCase {
    var home: URL!
    override func setUp() {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("dc-\(UUID().uuidString)")
        let dd = home.appendingPathComponent("Library/Developer/Xcode/DerivedData/App-abc")
        try! FileManager.default.createDirectory(at: dd, withIntermediateDirectories: true)
        try! Data(count: 300_000).write(to: dd.appendingPathComponent("blob"))
        let npm = home.appendingPathComponent(".npm/_cacache")
        try! FileManager.default.createDirectory(at: npm, withIntermediateDirectories: true)
        try! Data(count: 100_000).write(to: npm.appendingPathComponent("x"))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: home) }

    func testMeasureAndClean() {
        var calls: [[String]] = []
        let c = DiskCleaner(home: home, run: { _, args in calls.append(args); return (0, #"{"devices":{}}"#) })
        let t = c.measure()
        XCTAssertEqual(Set(t.map(\.id)), ["derivedData", "npm"])
        XCTAssertGreaterThanOrEqual(t.first { $0.id == "derivedData" }!.bytes, 300_000)
        let r = c.clean(["derivedData", "npm"])
        XCTAssertEqual(r.errors, [])
        XCTAssertGreaterThanOrEqual(r.freed, 400_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Developer/Xcode/DerivedData").path), "keeps the folder")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("Library/Developer/Xcode/DerivedData").path), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".npm/_cacache").path))
    }

    func testUnknownIdIsAnError() {
        let r = DiskCleaner(home: home, run: { _, _ in nil }).clean(["nope"])
        XCTAssertEqual(r.errors, ["Unknown target nope"])
    }
}
```

- [ ] **Step 2: Run them and check they fail.** Run `swift test --filter DiskCleanerTests`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them and check they pass.**
- [ ] **Step 5: Commit.** Message: "Measure and clean disk caches".

### Task 6: Actions and SystemWatch

**Files:**
- Create `Sources/WatchCore/SystemActions.swift` and `Sources/WatchCore/SystemWatch.swift`.

```swift
public enum SystemAction: Sendable, Equatable { case quitApp(String), kill(Int32), closeIdleClaude, clean([String]) }
public enum SystemActions {
    /// Blocking (up to ~30 s). Returns (ok, message).
    public static func run(_ a: SystemAction, snapshot: Snapshot?, apps: [AppUsage], force: Bool = false) -> (ok: Bool, message: String)
}
```

What each action does:

- **quitApp(id)**:
  - `"claude:<pid>"` → `NSRunningApplication(processIdentifier:)?.terminate()`.
  - A bundle path → every `NSWorkspace.shared.runningApplications` entry whose `bundleURL?.standardizedFileURL.path == id` → `terminate()`.
  - A plain process name (from the auto list) → SIGTERM every own process with that name (through `KillGuard.allowsLive`).
  - Wait up to 10 s for exit. With `force` and still alive, SIGKILL the main pids. Message: "Quit Docker" / "Docker is still running (it may be asking to save)".
- **kill(pid)**: `KillGuard.allowsLive(pid)` → `kill(pid, SIGKILL)`. Message: "Killed qemu-system-aarch64 (4411)".
- **closeIdleClaude**:
  - Candidates are `snapshot.profiles` that have a running pid (`ClaudeProcesses.pid(for:in:)`) and no session in `snapshot.accounts.flatMap(\.sessions)` with that `profileId` whose activity is `.working` or `.waiting`.
  - `WindowControl.quit(idle)`.
  - Message: "Closed Hamagan, Lajward · kept Main (busy)", or "No idle Claude windows".
- **clean(ids)**: `DiskCleaner().clean(ids)`. Message: "Freed 14.2 GB", plus errors.

`SystemWatch` (final class, own serial queue, 5 s timer):

```swift
public final class SystemWatch: @unchecked Sendable {
    public init(config: @escaping () -> SystemConfig)
    public var onSample: ((SystemHealth) -> Void)?             // every reading
    public var onAlert: ((HealthLevel, SystemHealth) -> Void)?
    public var onAutoAct: ((SystemHealth) -> Void)?
    public private(set) var latest: SystemHealth?               // full history
    public func start(); public func stop()
    public func refreshCleanable()                              // re-measure now (after a clean)
}
```

On each tick:

1. Take probe readings.
2. `ProcessScan.sample()`, grouped with `NSWorkspace` running apps (`bundleURL.path` → pid, `localizedName`).
3. `claudeNames` = map `ClaudeProcesses.list()` instances to profile names, using `ProfileDiscovery` (match `ClaudeProcesses.pid(for:in:)`).
4. `HealthRules.evaluate`.
5. Append the history point (cap 360).
6. `cleanable` comes from the last measurement, re-measured on a utility queue every 10 min.
7. `HealthAlerter.feed`, then the callbacks.

- [ ] **Step 1: Implement.** These pieces touch the live system; the logic they use is covered by Tasks 3–5.
- [ ] **Step 2: Build.** Run `swift build`. Expected: success.
- [ ] **Step 3: Smoke test.** Add `testSystemWatchProducesAReading` to `SystemProbeTests`: create `SystemWatch(config: { SystemConfig() })`, call `start()`, wait (an expectation on `onSample`, 8 s), check `latest?.memTotal > 0` and `!(latest?.apps.isEmpty ?? true)`, then `stop()`. Run `swift test --filter SystemProbeTests`. Expected: pass.
- [ ] **Step 4: Commit.** Message: "Sample system health on a timer and run system actions".

### Task 7: Bridge routes, WebSocket watch and commands

**Files:**
- Modify `Sources/WatchBridge/Server.swift`.
- Test: `Tests/WatchBridgeTests/ServerTests.swift`.

Changes:

- `BridgeCommand` gains:
  - `.quitApp(appId: String)` → name `"quit-app"`, target appId
  - `.killProcess(pid: Int32)` → name `"kill"`, target `"\(pid)"`
  - `.closeIdleClaude` → name `"close-idle-claude"`, target nil
  - `.cleanDisk(targets: [String])` → name `"clean-disk"`, target joined by `,`
  - `.setAutoAct(enabled: Bool)` → name `"auto-act"`, target `"on"`/`"off"`
- `BridgeHandler` gains `func systemHealth() -> SystemHealth?`.
- `route`: `case ("GET", 1, "system"): return handler.systemHealth().map { .json($0) } ?? .error(503, "No reading yet")`.
- `command` gets these cases:

```swift
case ("system", 3, "quit") where p[1] == "apps": cmd = req.decode(QuitAppBody.self).map { .quitApp(appId: $0.appId) }
case ("system", 3, "kill") where p[1] == "processes": cmd = req.decode(KillBody.self).map { .killProcess(pid: $0.pid) }
case ("system", 3, "close-idle") where p[1] == "claude": cmd = .closeIdleClaude
case ("system", 3, "clean") where p[1] == "disk": cmd = req.decode(CleanBody.self).flatMap { $0.targets.isEmpty ? nil : .cleanDisk(targets: $0.targets) }
case ("system", 2, "auto"): cmd = req.decode(AutoActBody.self).map { .setAutoAct(enabled: $0.enabled) }
```

The existing switch matches on `(p.first, p.count, p.last)`, so `where` clauses on `p[1]` work.

- `Conn` gains `var watchingSystem = false`.
- In `onFrame`:
  - `.watchSystem` sets the flag and sends `.system(full)` from `handler?.systemHealth()`.
  - `.unwatchSystem` clears it.
- `public func publish(system h: SystemHealth)`: on the queue, encode `.system(h.latestOnly)` once and send it to `conns` where `isSocket && watchingSystem`.

- [ ] **Step 1: Write the failing tests.**
  - Add `var health: SystemHealth?` and `func systemHealth() -> SystemHealth? { health }` to `FakeHandler`.
  - Copy the `sample(history:)` builder from `SystemWireTests` into a `ServerTests` extension as `static func health()`, since that test target can't see the other.

```swift
func testSystemRoutesAndCommands() async throws {
    let token = try await pair()
    let (none, _) = try await request("GET", "/v1/system", token: token)
    XCTAssertEqual(none, 503)
    handler.health = Self.health()
    let (ok, data) = try await request("GET", "/v1/system", token: token)
    XCTAssertEqual(ok, 200)
    XCTAssertEqual(try WireCoder.decoder.decode(SystemHealth.self, from: data).history.count, 3)

    let cases: [(String, Encodable, String)] = [
        ("/v1/system/apps/quit", QuitAppBody(appId: "/Applications/Docker.app"), "quit-app"),
        ("/v1/system/processes/kill", KillBody(pid: 4411), "kill"),
        ("/v1/system/claude/close-idle", PlainCommand(), "close-idle-claude"),
        ("/v1/system/disk/clean", CleanBody(targets: ["npm"]), "clean-disk"),
        ("/v1/system/auto", AutoActBody(enabled: true), "auto-act"),
    ]
    for (path, body, name) in cases {
        let (s, _) = try await request("POST", path, token: token, body: body)
        XCTAssertEqual(s, 202, path)
        XCTAssertEqual(handler.performed.last, name)
    }
    let (empty, _) = try await request("POST", "/v1/system/disk/clean", token: token, body: CleanBody(targets: []))
    XCTAssertEqual(empty, 400)
}
```

  - Stream test: after connecting a WebSocket (copy the setup from `testStreamSnapshotSubscriptionJobsAndRevoke`), send `{"type":"watchSystem"}`, expect a `system` message with 3 history points. Call `server.publish(system:)` and expect a `system` message with 1 point. Send `unwatchSystem`, publish again, and check no `system` message arrives within 0.5 s (a pong after a ping proves the order).

- [ ] **Step 2: Run them and check they fail.** Run `swift test --filter ServerTests`.
- [ ] **Step 3: Implement the server changes.**
- [ ] **Step 4: Run them and check they pass.** Run `swift test --filter ServerTests`, then the full `swift test`.
- [ ] **Step 5: Commit.** Message: "Serve system health and system commands over the bridge".

### Task 8: Mac app wiring

**Files:**
- Modify `Sources/ClaudeWatch/App.swift` and `Sources/ClaudeWatch/BridgeController.swift`.

`WatchModel`:

- `let system = SystemWatch(config: { WatchModel.shared.monitor.config.system })`. Capture `monitor` instead of `shared`, to avoid an init cycle: `SystemWatch(config: { [monitor] in monitor.config.system })` after `monitor` exists.
- `@Published var health: SystemHealth?`.
- In `init`, after the bridge is created:
  - `system.onSample = { h in bridge?.systemSample(h); main { self.health = h } }`
  - `system.onAlert = { l, h in self.notifySystem(l, h); bridge?.systemAlert(l, h) }`
  - `system.onAutoAct = { h in self.autoAct(h) }`
  - `system.start()`
- `func runSystem(_ a: SystemAction, completion: @escaping (Bool, String) -> Void)`: on a utility queue, `SystemActions.run(a, snapshot: snapshot, apps: health?.apps ?? [])`; after a clean, `system.refreshCleanable()`; then call back on main.
- `autoAct(h)`:
  1. Read `cfg = monitor.config.system.auto`.
  2. If `cfg.closeIdleClaude`, run `.closeIdleClaude`.
  3. For each id in `cfg.quitApps`, run `.quitApp(id)` with `force: cfg.forceIfStuck`.
  4. If `h.reasons` contains a disk reason (prefix `"disk "`) and `!cfg.cleanTargets.isEmpty`, run `.clean(cfg.cleanTargets)`.
  5. Gather the messages, call `bridge?.server.audit.append(device: "auto", command: "auto-act", target: nil, result: "done", reason: joined)`, and send a local plus push note: title "Session Watch acted on low memory", body joined.
- `notifySystem(level, h)`: a local `UNMutableNotificationContent`, title `"Mac \(level == .critical ? "critical" : "under pressure")"`, body `PushText.body(h)`.

`BridgeController`:

- `private var health: SystemHealth?` (lock).
- `func systemSample(_ h)`: store it; `server.publish(system: h)`; if `h.level != lastLevel`, `republish()`.
- `merge` sets `m.systemLevel = health?.level`.
- `func systemHealth() -> SystemHealth?` returns the stored one, with `auto` refreshed from `monitor.config.system.auto.summary`.
- `func systemAlert(_ level, _ h)`: `push(PushNote(category: "SYSTEM", title: SystemText.title(level), body: SystemText.body(h), collapseId: "system", userInfo: [:]), .system)`.
- `func pushAuto(_ text: String)` uses the same category.
- `check`:
  - `.quitApp(id)`: refuse 404 "That app isn't running any more" unless `health?.apps` contains id with `canQuit`.
  - `.killProcess(pid)`: `KillGuard.allowsLive(pid)` false → 403 with its message.
  - `.cleanDisk(t)`: unknown ids → 400.
- `run`: map to `SystemActions.run` (`ok` → `.done`, else `.failed`). After a clean, `systemWatch?.refreshCleanable()`. `.setAutoAct(on)` → `monitor.updateConfig { $0.system.auto.enabled = on }`, `(.done, nil)`.
- `BridgeController` needs a reference to `SystemWatch`: add `weak var systemWatch: SystemWatch?`, set by `WatchModel`.

Put `SystemText` (title/body formatting shared by the local and push notes) in `Sources/WatchCore/HealthRules.swift`:

- `title(level)`: `"Mac memory critical"` when `reasons.first` starts with swap or memory, else `"Mac \(reason-kind) critical/warning"`. Simple rule: `"Mac " + (level == .critical ? "critical" : "warning") + ": " + reasons.first`.
- `body(h)`: `reasons.joined(" · ")` + `" — "` + the top 2 apps by rss as `"Docker 6.1 GB"`.

Add a unit test in `HealthRulesTests` for `SystemText.body`.

- [ ] **Step 1: Write the `SystemText` test, implement it, and run it.**
- [ ] **Step 2: Implement the wiring.** Run `swift build`.
- [ ] **Step 3: Commit.** Message: "Run the system watch in the Mac app and push alerts".

### Task 9: Mac UI

**Files:**
- Create `Sources/ClaudeWatch/SystemPanel.swift`.
- Modify `App.swift` (`MainSection`), `MainWindow.swift` and `SettingsView.swift`.

`MainSection` gets `case system`, title `"system"`, symbol `"memorychip"`. Insert it after `chats`.

`MainWindow` gets `case .system: SystemPanel()`. The sidebar badge for `.system` is 1 when `model.health?.level != .ok`.

`SystemPanel` is a `ScrollView` of `Panel`s:

1. **Level banner:** a dot plus the level, with the reasons below it. Colours: `Theme.green`, `Theme.yellow`, `Theme.red`.
2. **Gauges:** four rows of label, value, `ProgressView(value:)` and `Sparkline(values:)` over `history`:
   - memory: `memUsed`/`memTotal`, plus "pressure warn"
   - swap: `swapUsed`/`swapTotal`
   - cpu: `load1`/`cores` and "load 6.2 · 10 cores"
   - disk: free of total; the bar shows used share
3. **Top apps:** `Table`-like rows of name, memory, CPU % and process count, with **Quit** and **Kill** buttons. `confirmationDialog` for Kill ("Kill X (pid N)? Unsaved work is lost.") and Quit.
4. **Actions:**
   - "Close idle Claude windows" with a confirmation.
   - "Free disk…" opens a sheet with checkboxes for the `cleanable` targets (label + size, "size unknown" for -1), a total, and a red "Delete" with a confirm.
   - Result text from `runSystem` is shown under the panel for 8 s.
5. **Auto-act summary line**, with a "Settings…" button setting `model.section = .settings`.

`Sparkline` is a private view: a `Path` normalised to min/max, stroked with `Theme.clay`, height 22.

`SettingsView` gets a "system" `Section` before "iphone"/bridge:

- Number fields "Disk warning" and "Disk critical" in GB, clamped to 1…2000, with critical < warning.
- `Toggle("Act automatically when critical")` bound to `\.system.auto.enabled`.
- `number("After", \.system.auto.afterSeconds as Double proxy …, unit: "s")`. Use a `Binding<Int>` clamp of 30…3600 with the existing `number` helper if it supports Int (it's used for `maxAttempts`, which is Int).
- `Toggle("Close idle Claude windows", \.system.auto.closeIdleClaude)` and `Toggle("Force-quit apps that don't quit in 30 s", \.system.auto.forceIfStuck)`.
- "Quit these apps": the list of `cfg.system.auto.quitApps`, each shown with its display name (looked up in `model.health?.apps`, else the id's last component) and a remove button. Below it, a `Menu("Add app")` listing `model.health?.apps` not already listed. Adding an app adds its id; for `pid:` rows it adds the process name instead, since pids change.
- "When disk is critical, also clean:" toggles for the `DiskCleaner.ids` minus `trash`.
- Footer: "Off by default. Session Watch only acts after the Mac has stayed critical for the delay, once per episode, and tells you what it did."

- [ ] **Step 1: Implement.** Run `swift build`.
- [ ] **Step 2: Run the app** (debug, `SW_NO_BRIDGE=1` so the installed app's bridge isn't disturbed) and check the system section renders with live numbers. Take a screenshot.
- [ ] **Step 3: Commit.** Message: "Show system health and actions in the Mac app".

### Task 10: iPhone

**Files:**
- Modify `iOS/ClaudeRemote/RemoteStore.swift`, `RemoteCommand.swift`, `Views/MacView.swift`, `Views/BottomBar.swift` and `Fixtures.swift`.
- Create `Views/SystemSection.swift`.

`RemoteStore`:

- `private(set) var system: SystemHealth?`, `@ObservationIgnored private var watchingSystem = false`.
- `func watchSystem()`: set the flag; if preview or demo, `system = Fixtures.system`; else, if connected, send `WSClientMessage(type: .watchSystem)`.
- `unwatchSystem()` mirrors it.
- `didConnect` re-sends `watchSystem` when the flag is set.
- `handle(.system(h))`:
  - If `h.history.count > 1 || system == nil`, set `system = h`.
  - Otherwise `var n = h`; `n.history = (system!.history + h.history).suffix(360)`; `system = n`.
- On `.background` scene phase the existing stop/start handles the socket. Watching resumes in `didConnect`.

`RemoteCommand` adds `quitApp(_ app: AppUsage)`, `kill(pid:name:)`, `closeIdleClaude()`, `cleanDisk(_ ids: [String])` and `setAutoAct(_ on: Bool)`, with paths per Task 7. Keys: `Keys.app(id)` = `"app:"+id`, `Keys.kill(pid)`, `Keys.closeIdle` and `Keys.clean`.

`SystemSection` sits in the `MacView` `LazyVStack` after the `StatusStrip` divider:

- `SectionTitle("system")`.
- A level line: a dot, the level and the reasons (mono small).
- Four gauge rows of key and value, with a `Sparkline` (local `Path` view) under each.
- `SectionTitle("top apps")` and rows of name, memory and CPU.
  - Long-press `contextMenu` with Quit and Kill, plus trailing `swipeActions`. A `LazyVStack` isn't a List, so use contextMenu plus a trailing "⋯" `Menu` button per row.
- Buttons:
  - "close idle claude"
  - "free disk…", which opens a sheet with toggles per target, the size, and a red "delete N GB" with `.confirmationDialog`
- Auto line: `Toggle("auto-act when critical")` sending `.setAutoAct`, with the summary text below ("quits Docker, qemu after 2 min").
- `.onAppear { store.watchSystem() }`, `.onDisappear { store.unwatchSystem() }`.
- Results go through the existing `store.perform(cmd)`, whose toast shows the job reason.

The `MacView` notify title gets `case .system: "mac under pressure"`.

In `BottomBar.status(tab)` for `.mac`, if `store.snapshot?.systemLevel` is `.warn` or `.critical`, show a dot in yellow or red. Read the existing `status(_:)` body and add the condition in the same style.

`Fixtures.system`: a `SystemHealth` with level warn, the reasons "swap 8.1/10 GB", 60 history points of gentle sine data, and apps for Docker, qemu-system-aarch64, Google Chrome, "Claude · Hamagan" and python3. It also has cleanable DerivedData 14.2 GB and npm cache 2.1 GB.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Build for the simulator:** `cd iOS && xcodebuild -project ClaudeRemote.xcodeproj -scheme ClaudeRemote -destination 'generic/platform=iOS Simulator' -quiet build`. Expected: BUILD SUCCEEDED.
- [ ] **Step 3: Run it** in the simulator in demo mode and screenshot the Mac tab system section.
- [ ] **Step 4: Commit.** Message: "Show Mac system health and actions on the iPhone".

### Task 11: End-to-end check and docs

- [ ] Run the full `swift test`. Expected: all pass.
- [ ] Run the debug Mac app with the bridge on a spare port (`CLAUDE_WATCH_DEV_PAIR_CODE=123456`, port via config is not possible without touching the user config, so use the existing dev path the README documents), pair the simulator, open the Mac tab, check live numbers update, quit TextEdit from the phone, and confirm the job is done.
- [ ] Update `README.md` with a short "System health" section: what it shows, the alert rule, actions, and the auto-act settings.
- [ ] Commit. Message: "Document system health".
