import AppKit
import Foundation

/// Samples the Mac's resources every 5 s, keeps 30 minutes of history, and says when to alert or auto-act.
public final class SystemWatch: @unchecked Sendable {
    public static let interval: TimeInterval = 5
    public static let historyLength = 360

    /// Called on the watch's queue after every reading.
    public var onSample: ((SystemHealth) -> Void)?
    public var onAlert: ((HealthLevel, SystemHealth) -> Void)?
    public var onAutoAct: ((SystemHealth) -> Void)?

    private let config: () -> SystemConfig
    private let profiles: () -> [Profile]
    private let queue = DispatchQueue(label: "claude-watch.system", qos: .utility)
    private let measureQueue = DispatchQueue(label: "claude-watch.system-measure", qos: .background)
    private let scan = ProcessScan()
    private var alerter = HealthAlerter()
    private var history: [HealthPoint] = []
    private var claudeNames: [Int32: String] = [:]
    private var claudeNamesAt = Date.distantPast
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var _latest: SystemHealth?
    private var _cleanable: [CleanTarget] = []
    private var measuring = false
    private var measuredAt = Date.distantPast

    public init(config: @escaping () -> SystemConfig, profiles: @escaping () -> [Profile]) {
        self.config = config
        self.profiles = profiles
    }

    /// The newest reading, with the full history.
    public var latest: SystemHealth? { lock.withLock { _latest } }

    public func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: Self.interval, leeway: .milliseconds(500))
            t.setEventHandler { [weak self] in self?.tick() }
            timer = t
            t.resume()
        }
    }

    public func stop() {
        queue.sync { timer?.cancel(); timer = nil }
    }

    /// Re-measures the disk targets now (after a clean).
    public func refreshCleanable() {
        measureQueue.async { [self] in
            let t = DiskCleaner().measure()
            lock.withLock { _cleanable = t; measuredAt = Date() }
        }
    }

    private func tick() {
        let now = Date()
        let cfg = config()
        let mem = SystemProbe.memory(), swap = SystemProbe.swap(), load = SystemProbe.load(), disk = SystemProbe.disk()
        let pressure = SystemProbe.pressure()
        let thermal = ProcessInfo.processInfo.thermalState
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let (level, reasons) = HealthRules.evaluate(
            HealthInputs(pressure: pressure, swapUsed: swap.used, swapTotal: swap.total, diskFree: disk.free,
                         load5: load.five, cores: cores, thermal: thermal), cfg)

        if now.timeIntervalSince(claudeNamesAt) > 30 {
            let instances = ClaudeProcesses.list()
            claudeNames = Dictionary(profiles().compactMap { p in ClaudeProcesses.pid(for: p, in: instances).map { ($0, p.name) } },
                                     uniquingKeysWith: { a, _ in a })
            claudeNamesAt = now
        }
        var appPids: [String: Int32] = [:], appNames: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let path = app.bundleURL?.standardizedFileURL.path else { continue }
            appPids[path] = appPids[path] ?? app.processIdentifier
            if let n = app.localizedName { appNames[path] = n }
        }
        let myUid = getuid(), me = getpid()
        let apps = AppGrouper.group(scan.sample(), appPid: { appPids[$0] }, appName: { appNames[$0] },
                                    claudeNames: claudeNames,
                                    guardFn: { KillGuard.allows(pid: $0.pid, name: $0.name, ownerUid: myUid, myUid: myUid, selfPid: me) })

        history.append(HealthPoint(at: now, memUsed: mem.used, swapUsed: swap.used, diskFree: disk.free, load1: load.one))
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }

        let (cleanable, measuredAt) = lock.withLock { (_cleanable, self.measuredAt) }
        if now.timeIntervalSince(measuredAt) > 600, !lock.withLock({ measuring }) {
            lock.withLock { measuring = true }
            measureQueue.async { [self] in
                let t = DiskCleaner().measure()
                lock.withLock { _cleanable = t; self.measuredAt = Date(); measuring = false }
            }
        }

        let h = SystemHealth(at: now, level: level, reasons: reasons, pressure: pressure, memTotal: mem.total, memUsed: mem.used,
                             memCompressed: mem.compressed, swapUsed: swap.used, swapTotal: swap.total, diskFree: disk.free,
                             diskTotal: disk.total, load1: load.one, load5: load.five, cores: cores,
                             thermal: HealthRules.thermalName(thermal), apps: apps, cleanable: cleanable, history: history,
                             auto: cfg.auto.summary)
        lock.withLock { _latest = h }
        let decision = alerter.feed(level, at: now, autoEnabled: cfg.auto.enabled, autoAfter: TimeInterval(cfg.auto.afterSeconds))
        onSample?(h)
        if let l = decision.alert { onAlert?(l, h) }
        if decision.autoAct { onAutoAct?(h) }
    }
}
