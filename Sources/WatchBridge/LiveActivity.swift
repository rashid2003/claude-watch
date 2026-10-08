import Foundation
import WatchProtocol

/// One Live Activity push: start, update or end, with `LiveLimits` as the content state.
public struct ActivityPush: Sendable, Equatable {
    public enum Event: String, Sendable { case start, update, end }
    /// Must match the iPhone's `ActivityAttributes` type name; push-to-start looks it up by name.
    public static let attributesType = "LimitsActivityAttributes"

    public var event: Event
    public var state: LiveLimits
    public var macName: String
    public var important: Bool
    public var now: Date

    public init(event: Event, state: LiveLimits, macName: String, important: Bool, now: Date) {
        self.event = event; self.state = state; self.macName = macName; self.important = important; self.now = now
    }

    /// The activity shows as disconnected if nothing arrives for this long (the Mac asleep, quit or offline).
    public static let staleAfter: TimeInterval = LiveLimits.staleAfter

    /// The Mac's goodbye before it sleeps or quits: the latest numbers marked offline, sent at once.
    public static func offline(_ state: LiveLimits, reason: String, macName: String, now: Date) -> ActivityPush {
        ActivityPush(event: .update, state: state.goingOffline(reason), macName: macName, important: true, now: now)
    }

    /// The Mac said it is going away (sleep or quit).
    public var isOffline: Bool { state.offline != nil }

    /// When the phone should treat this content as out of date; nil for an end. A goodbye is stale at once, so even
    /// widget builds that don't know `LiveLimits.offline` show the Mac as offline straight away.
    public var staleDate: Date? {
        if event == .end { return nil }
        return isOffline ? now : now.addingTimeInterval(Self.staleAfter)
    }

    public func payload() -> Data {
        let content = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(state))) ?? [:]
        let t = Int(now.timeIntervalSince1970)
        var aps: [String: Any] = ["timestamp": t, "event": event.rawValue, "content-state": content]
        switch event {
        case .start:
            aps["attributes-type"] = Self.attributesType
            aps["attributes"] = ["macName": macName]
            aps["alert"] = ["title": "Claude limits", "body": "Tracking your accounts on the Lock Screen."]
        case .update:
            break
        case .end:
            aps["dismissal-date"] = t
        }
        if let staleDate { aps["stale-date"] = Int(staleDate.timeIntervalSince1970) }
        return (try? JSONSerialization.data(withJSONObject: ["aps": aps], options: [.sortedKeys])) ?? Data()
    }

    /// 10 sends now and counts against a budget; 5 is delivered when convenient and is free.
    public var priority: Int { important || event != .update ? 10 : 5 }
}

/// Decides when to start, update, restart and end each phone's Live Activity from the Mac's snapshots.
///
/// Updates are rationed: a change in an account's state or in the prompts waiting goes out at once; a percent that
/// crept up waits until `minorInterval` since the last send; and a quiet activity still gets a heartbeat, so it only
/// goes stale (and shows the Mac as offline) when the Mac stops sending. Heartbeats are priority 5, which Apple
/// doesn't count against the push budget; one every 5 minutes is 12 an hour. Activities live 8 hours, so one near
/// its end is replaced with a fresh one.
///
/// When the Mac sleeps or quits it sends each activity a last update marked offline (`goingOffline`) and then
/// holds back until `resume`, so a snapshot taken on the way down can't undo it. After waking, the next snapshot
/// goes out at once.
public final class LiveActivityDriver: @unchecked Sendable {
    public static let minorInterval: TimeInterval = 120
    /// Well inside `ActivityPush.staleAfter`, so one late or dropped low-priority push doesn't show the Mac as offline.
    public static let heartbeat: TimeInterval = 5 * 60
    public static let rollover: TimeInterval = 7 * 3600 + 45 * 60
    public static let startRetry: TimeInterval = 10 * 60
    public static let appOpenWindow: TimeInterval = 90

    struct Sent { var state: LiveLimits; var at: Date }

    private let lock = NSLock()
    private var sent: [String: Sent] = [:]          // device id → last update sent to its current token
    private var startTried: [String: Date] = [:]
    private var suspended = false

    public init() {}

    /// The Mac is going to sleep or quitting: stops planning updates and returns the offline update for each running
    /// activity. Devices without a running activity, or that switched it off, get nothing.
    public func goingOffline(_ devices: [Device], _ limits: LiveLimits, reason: String, macName: String,
                             now: Date = Date()) -> [(deviceId: String, token: String, push: ActivityPush)] {
        lock.withLock {
            suspended = true
            return devices.compactMap { d in
                guard d.liveActivity == true, let token = d.activityToken else { return nil }
                let push = ActivityPush.offline(limits, reason: reason, macName: macName, now: now)
                sent[d.id] = Sent(state: push.state, at: now)
                return (d.id, token, push)
            }
        }
    }

    /// The Mac woke up: plan again, and send every activity the latest numbers on the next snapshot.
    public func resume() {
        lock.withLock {
            suspended = false
            sent = [:]
        }
    }

    public var isSuspended: Bool { lock.withLock { suspended } }

    /// What to send to this device now, if anything. Call with every snapshot.
    public func plan(for d: Device, _ limits: LiveLimits, macName: String, now: Date = Date()) -> [(token: String, push: ActivityPush)] {
        lock.withLock {
            guard !suspended else { return [] }
            guard d.liveActivity == true else {
                sent[d.id] = nil
                return d.activityToken.map { [($0, ActivityPush(event: .end, state: limits, macName: macName, important: true, now: now))] } ?? []
            }
            var out: [(String, ActivityPush)] = []
            var token = d.activityToken
            // Near the 8-hour cap: end this one and start a fresh one, when the phone gave us a way to.
            if let t = token, let started = d.activityStartedAt, now.timeIntervalSince(started) > Self.rollover,
               d.activityStartToken != nil, startTried[d.id].map({ now.timeIntervalSince($0) > Self.startRetry }) ?? true {
                out.append((t, ActivityPush(event: .end, state: limits, macName: macName, important: true, now: now)))
                token = nil
            }
            guard let token else {
                // While the app is open it starts its own; a remote start then would make a second one.
                let appOpen = d.lastSeenAt.map { now.timeIntervalSince($0) < Self.appOpenWindow } ?? false
                guard !appOpen, let start = d.activityStartToken,
                      startTried[d.id].map({ now.timeIntervalSince($0) > Self.startRetry }) ?? true else { return out }
                startTried[d.id] = now
                sent[d.id] = nil
                out.append((start, ActivityPush(event: .start, state: limits, macName: macName, important: true, now: now)))
                return out
            }
            let last = sent[d.id]
            let important = last.map { Self.isImportant(from: $0.state, to: limits) } ?? true
            let changed = last.map { $0.state.comparable != limits.comparable } ?? true
            let age = last.map { now.timeIntervalSince($0.at) } ?? .infinity
            guard important || (changed && age >= Self.minorInterval) || age >= Self.heartbeat else { return out }
            sent[d.id] = Sent(state: limits, at: now)
            out.append((token, ActivityPush(event: .update, state: limits, macName: macName, important: important, now: now)))
            return out
        }
    }

    /// The token was rejected or replaced: start over with the next one.
    public func forget(_ deviceId: String) {
        lock.withLock { sent[deviceId] = nil }
    }

    /// A state change, a prompt appearing or going, an account joining or leaving, or a window crossing 90% or resetting.
    static func isImportant(from a: LiveLimits, to b: LiveLimits) -> Bool {
        guard a.prompts == b.prompts, a.accounts.map(\.id) == b.accounts.map(\.id) else { return true }
        for (x, y) in zip(a.accounts, b.accounts) {
            if x.state != y.state || x.limitedUntil != y.limitedUntil { return true }
            for (p, q) in [(x.five, y.five), (x.week, y.week)] {
                let p = p ?? 0, q = q ?? 0
                if (p < 90) != (q < 90) || q + 10 < p { return true }   // crossed 90%, or dropped (a reset)
            }
        }
        return false
    }
}

extension Pusher {
    /// Sends a Live Activity push. `gone` runs when Apple says the token is no longer valid. `done` runs once with
    /// the HTTP status when Apple answered, or 0 when the push didn't go out (no key, no network).
    public func send(_ push: ActivityPush, token: String, environment: String?, gone: @escaping @Sendable () -> Void,
                     done: (@Sendable (Int) -> Void)? = nil) {
        guard let r = request(push, token: token, environment: environment) else { done?(0); return }
        session.dataTask(with: r) { [weak self] data, resp, err in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            defer { done?(status) }
            if status == 200 { return }
            let reason = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }?["reason"] as? String
            self?.lastError = "Live Activity push failed: \(reason ?? err?.localizedDescription ?? "HTTP \(status)")"
            if status == 410 || reason == "BadDeviceToken" || reason == "Unregistered" { gone() }
        }.resume()
    }

    /// The APNs request for a Live Activity push; nil without a key or token.
    func request(_ push: ActivityPush, token: String, environment: String?) -> URLRequest? {
        guard let key, !token.isEmpty else { return nil }
        let host = environment == "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com"
        guard let url = URL(string: "https://\(host)/3/device/\(token)"), let jwt = try? jwt() else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        r.setValue(key.topic + ".push-type.liveactivity", forHTTPHeaderField: "apns-topic")
        r.setValue("liveactivity", forHTTPHeaderField: "apns-push-type")
        r.setValue(String(push.priority), forHTTPHeaderField: "apns-priority")
        r.httpBody = push.payload()
        return r
    }
}
