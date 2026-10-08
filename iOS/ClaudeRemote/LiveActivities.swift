import ActivityKit
import BackgroundTasks
import Foundation
import Observation
import UIKit
import WatchProtocol
import WidgetKit

/// Keeps the limits Live Activity on the Lock Screen (and in the Dynamic Island, and the Mac's menu bar when the
/// phone is nearby) and the home-screen widgets in step with the Mac.
///
/// While the app runs it updates the activity itself; once it is in the background the Mac takes over with
/// Live Activity pushes, using the tokens this hands it. The Mac can also start a fresh activity when the
/// 8-hour one runs out. When the app loses the Mac for a while it marks the activity disconnected itself.
@MainActor @Observable
final class LiveActivities {
    private static let enabledKey = "liveActivity.enabled"
    private static let localInterval: TimeInterval = 20
    private static let widgetInterval: TimeInterval = 60
    /// How long the app must be cut off from the Mac before the activity says so (rides out quick reconnects).
    private static let offlineGrace: TimeInterval = 30

    /// The user wants the limits on the Lock Screen. On by default.
    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            Task { await apply() }
        }
    }

    /// Live Activities are allowed in Settings › Session Watch.
    private(set) var allowed = ActivityAuthorizationInfo().areActivitiesEnabled
    private(set) var running = false

    /// Sends a registration to the Mac; returns whether it went through.
    @ObservationIgnored var register: ((DeviceRegistration) async -> Bool)?
    @ObservationIgnored private var latest: (limits: LiveLimits, macName: String)?
    @ObservationIgnored private var lastLocal: (state: LiveLimits, at: Date)?
    @ObservationIgnored private var lastWidget: (state: LiveLimits, at: Date)?
    @ObservationIgnored private var sentTokens: [String: String] = [:]   // what the Mac already has, by field
    @ObservationIgnored private var watched: Set<String> = []
    @ObservationIgnored private var started = false
    @ObservationIgnored private var offlineTimer: Task<Void, Never>?
    @ObservationIgnored private var markedOffline = false
    @ObservationIgnored private var lostAt: Date?        // when the app lost the Mac; nil while connected
    @ObservationIgnored private var activeSince: Date?   // when the app came to the front; nil when it isn't

    init() {
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    private typealias LimitsActivity = Activity<LimitsActivityAttributes>

    /// Starts listening for tokens and for activities the Mac starts. Call once, at launch.
    func start() {
        guard !started else { return }
        started = true
        observeForeground()
        Task {
            for await token in LimitsActivity.pushToStartTokenUpdates {
                await send(field: "start", token.hex)
            }
        }
        Task {
            for await activity in LimitsActivity.activityUpdates { watch(activity) }
        }
        Task {
            for await info in ActivityAuthorizationInfo().activityEnablementUpdates {
                allowed = info
                await apply()
            }
        }
        for a in LimitsActivity.activities { watch(a) }
        running = LimitsActivity.activities.contains { $0.activityState == .active }
    }

    /// Feed every snapshot here.
    func update(_ snap: Snapshot, macName: String, now: Date = Date()) {
        update(LiveLimits(snap), macName: macName, now: now)
    }

    func update(_ limits: LiveLimits, macName: String, now: Date = Date()) {
        latest = (limits, macName)
        if lastWidget.map({ $0.state.comparable != limits.comparable || now.timeIntervalSince($0.at) > 900 }) ?? true,
           now.timeIntervalSince(lastWidget?.at ?? .distantPast) > Self.widgetInterval {
            lastWidget = (limits, now)
            WidgetShare.save(limits, macName: macName, at: now)
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetShare.kind)
        }
        guard enabled, allowed else { return }
        if let current = LimitsActivity.activities.first(where: { $0.activityState == .active }) {
            guard lastLocal.map({ $0.state.comparable != limits.comparable && now.timeIntervalSince($0.at) > Self.localInterval
                || now.timeIntervalSince($0.at) > 600 }) ?? true else { return }
            lastLocal = (limits, now)
            markedOffline = false
            Task { await current.update(content(limits, now)) }
        } else {
            Task { await apply() }
        }
    }

    /// Follows the app's own connection to the Mac. Lost for `offlineGrace` while the app is in front, the activity
    /// is marked disconnected; back, it shows the latest limits again.
    func reachable(_ yes: Bool) {
        if yes {
            lostAt = nil
            armOfflineTimer()
            guard markedOffline else { return }
            lastLocal = nil   // the next snapshot clears the mark, without waiting out the throttle
            if let latest { update(latest.limits, macName: latest.macName) }
        } else if lostAt == nil {
            lostAt = Date()
            armOfflineTimer()
        }
    }

    /// Times the offline mark from whichever came later, losing the Mac or the app coming to the front, so the
    /// reconnect after a stretch in the background doesn't flash "offline".
    private func armOfflineTimer() {
        offlineTimer?.cancel()
        offlineTimer = nil
        guard let lostAt, let activeSince, !markedOffline else { return }
        let due = max(lostAt, activeSince).addingTimeInterval(Self.offlineGrace)
        offlineTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, due.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.markOffline()
        }
    }

    /// Tracks when the app came to the front; the offline timer only runs while it's there.
    private func observeForeground() {
        let center = NotificationCenter.default
        activeSince = UIApplication.shared.applicationState == .active ? Date() : nil
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.activeSince = Date()
                self?.armOfflineTimer()
            }
        }
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.activeSince = nil
                self?.armOfflineTimer()
            }
        }
    }

    /// Paired with a Mac: give the widgets a way to reach it. Unpaired: clear everything.
    func paired(_ c: Credentials?) {
        if let c {
            WidgetShare.Link(baseURLs: c.baseURLs, token: c.token, macName: c.macName).save()
            sentTokens = [:]
            Task { await resendTokens() }
        } else {
            WidgetShare.clear()
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetShare.kind)
            sentTokens = [:]
            Task { for a in LimitsActivity.activities { await a.end(nil, dismissalPolicy: .immediate) } }
        }
    }

    // MARK: Background refresh

    /// A fallback for when the Mac can't push (no APNs key set up there): every so often iOS wakes the app,
    /// which asks the Mac directly and refreshes the activity and the widgets.
    static let refreshTask = "dev.lajward.SessionWatch.refresh"

    func registerBackgroundRefresh() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTask, using: nil) { [weak self] task in
            Task { @MainActor in
                self?.scheduleRefresh()
                let work = Task { @MainActor in
                    guard let self, let link = WidgetShare.Link.load(), let fresh = await link.fetch() else { return false }
                    self.lastWidget = nil
                    self.update(fresh, macName: link.macName)
                    return true
                }
                task.expirationHandler = { work.cancel() }
                task.setTaskCompleted(success: await work.value)
            }
        }
    }

    func scheduleRefresh() {
        guard WidgetShare.Link.load() != nil else { return }
        let r = BGAppRefreshTaskRequest(identifier: Self.refreshTask)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }

    // MARK: Private

    private func content(_ l: LiveLimits, _ now: Date) -> ActivityContent<LiveLimits> {
        ActivityContent(state: l, staleDate: now.addingTimeInterval(LiveLimits.staleAfter),
                        relevanceScore: l.anyLimited || l.prompts > 0 ? 100 : 50)
    }

    /// Keeps the last numbers (and when the Mac sent them) but flags them as disconnected and already stale.
    /// In the background the Mac's pushes own the activity, so this only acts while the app is in front.
    private func markOffline() {
        offlineTimer = nil
        guard activeSince != nil, lostAt != nil, enabled, allowed,
              let current = LimitsActivity.activities.first(where: { $0.activityState == .active }) else { return }
        markedOffline = true
        var state = current.content.state
        state.connected = false
        lastLocal = (state, Date())
        Task { await current.update(ActivityContent(state: state, staleDate: Date(), relevanceScore: 50)) }
    }

    /// Starts or ends the activity to match `enabled`, and tells the Mac.
    private func apply() async {
        if !enabled || !allowed {
            for a in LimitsActivity.activities { await a.end(nil, dismissalPolicy: .immediate) }
            running = false
            _ = await register?(DeviceRegistration(environment: Self.environment, liveActivity: false, activityToken: ""))
            sentTokens["update"] = ""
            return
        }
        _ = await register?(DeviceRegistration(environment: Self.environment, liveActivity: true))
        guard LimitsActivity.activities.first(where: { $0.activityState == .active }) == nil, let latest else { return }
        do {
            let a = try LimitsActivity.request(attributes: LimitsActivityAttributes(macName: latest.macName),
                                               content: content(latest.limits, Date()), pushType: .token)
            lastLocal = (latest.limits, Date())
            markedOffline = false
            watch(a)
        } catch {
            // Too many activities, or the app is in the background: the Mac starts one with push-to-start instead.
        }
    }

    private func watch(_ a: LimitsActivity) {
        guard watched.insert(a.id).inserted else { return }
        running = true
        Task {
            for await token in a.pushTokenUpdates { await send(field: "update", token.hex) }
        }
        Task {
            for await state in a.activityStateUpdates where state == .dismissed || state == .ended {
                watched.remove(a.id)
                running = LimitsActivity.activities.contains { $0.activityState == .active && $0.id != a.id }
                if !running { await send(field: "update", "") }
            }
        }
    }

    private func send(field: String, _ token: String) async {
        guard sentTokens[field] != token else { return }
        let r = field == "start"
            ? DeviceRegistration(environment: Self.environment, activityStartToken: token)
            : DeviceRegistration(environment: Self.environment, liveActivity: enabled, activityToken: token)
        if await register?(r) == true { sentTokens[field] = token }
    }

    private func resendTokens() async {
        if let t = LimitsActivity.pushToStartToken { await send(field: "start", t.hex) }
        for a in LimitsActivity.activities where a.activityState == .active {
            if let t = a.pushToken { await send(field: "update", t.hex) }
        }
        _ = await register?(DeviceRegistration(environment: Self.environment, liveActivity: enabled && allowed))
    }

    static var environment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
