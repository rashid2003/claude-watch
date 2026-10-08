import Foundation

/// What the Live Activity and the widgets show: each account's 5-hour and weekly use, plus what needs you.
/// It is also the Live Activity's `content-state`, sent by the Mac over APNs, so it stays small (APNs caps a
/// Live Activity payload at 4 KB) and uses plain numbers for times (seconds since 1970) so the iPhone decodes
/// the pushed JSON the same way it decodes its own.
public struct LiveLimits: Codable, Hashable, Sendable {
    public static let maxAccounts = 4

    public struct Account: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String          // short: "lajward.dev (Hamagan)" → "lajward.dev"
        public var org: String?
        public var state: AccountState
        public var five: Int?            // whole percent
        public var week: Int?
        public var fiveResets: Double?   // unix seconds
        public var weekResets: Double?
        public var limitedUntil: Double?
        public var working: Int

        public init(id: String, name: String, org: String? = nil, state: AccountState, five: Int? = nil, week: Int? = nil,
                    fiveResets: Double? = nil, weekResets: Double? = nil, limitedUntil: Double? = nil, working: Int = 0) {
            self.id = id; self.name = name; self.org = org; self.state = state; self.five = five; self.week = week
            self.fiveResets = fiveResets; self.weekResets = weekResets; self.limitedUntil = limitedUntil; self.working = working
        }

        public var limitedUntilDate: Date? { limitedUntil.map { Date(timeIntervalSince1970: $0) } }
        public var fiveResetsDate: Date? { fiveResets.map { Date(timeIntervalSince1970: $0) } }
        public var weekResetsDate: Date? { weekResets.map { Date(timeIntervalSince1970: $0) } }
        /// The higher of the two windows: how close this account is to being stopped.
        public var pressure: Int { max(five ?? 0, week ?? 0) }
    }

    public var accounts: [Account]
    public var hidden: Int               // accounts left out to stay under the cap
    public var prompts: Int
    public var working: Int
    /// When the Mac took the snapshot (unix seconds): "last seen" once the activity goes stale.
    public var updated: Double
    /// False when the iPhone app itself lost the Mac, or when the Mac said it was going away (see `offline`).
    /// The Mac's ordinary pushes leave it out, so any later push from it clears this.
    /// Optional so content from older Macs and apps still decodes.
    public var connected: Bool?
    /// Set in the Mac's last push before it sleeps or quits: why it went away (`Offline.sleep`, `Offline.quit`).
    /// That push also sets `connected` to false and a stale date of now, so widget builds that don't know this
    /// field still show the Mac as offline at once. A string, not an enum, so a reason added later still decodes.
    public var offline: String?

    public enum Offline {
        public static let sleep = "sleep"
        public static let quit = "quit"
    }

    /// How long a Live Activity counts as current without a fresh update (the Mac sends heartbeats well inside this).
    public static let staleAfter: TimeInterval = 12 * 60

    public init(accounts: [Account], hidden: Int = 0, prompts: Int = 0, working: Int = 0, updated: Double,
                connected: Bool? = nil, offline: String? = nil) {
        self.accounts = accounts; self.hidden = hidden; self.prompts = prompts; self.working = working; self.updated = updated
        self.connected = connected; self.offline = offline
    }

    public var updatedDate: Date { Date(timeIntervalSince1970: updated) }

    /// Cut off from the Mac: the phone lost it, or the Mac said it was going to sleep or quitting.
    public var disconnected: Bool { connected == false || offline != nil }

    /// The same numbers, marked as the Mac's goodbye before it sleeps or quits.
    public func goingOffline(_ reason: String) -> LiveLimits {
        var l = self
        l.connected = false
        l.offline = reason
        return l
    }

    /// The account to feature where there's room for one: limited first (soonest back), then the busiest.
    public var headline: Account? {
        let limited = accounts.filter { $0.state == .limited }
        if !limited.isEmpty { return limited.min { ($0.limitedUntil ?? .infinity) < ($1.limitedUntil ?? .infinity) } }
        return accounts.max { $0.pressure < $1.pressure }
    }

    public var anyLimited: Bool { accounts.contains { $0.state == .limited } }

    /// The same content without the time it was built, for telling whether anything worth sending changed.
    public var comparable: LiveLimits { var c = self; c.updated = 0; return c }

    public init(_ snap: Snapshot) {
        let working: (SessionStatus) -> Bool = { !$0.info.isArchived && $0.activity == .working }
        let rows: [Account] = snap.accounts.map { a in
            let n = Self.split(a.profile.name)
            return Account(id: a.id, name: n.title, org: n.org, state: a.running || a.state == .offline ? a.state : .offline,
                           five: a.fiveHour.percent.map { Int($0.rounded()) }, week: a.weekly.percent.map { Int($0.rounded()) },
                           fiveResets: a.fiveHour.resetsAt?.timeIntervalSince1970.rounded(),
                           weekResets: a.weekly.resetsAt?.timeIntervalSince1970.rounded(),
                           limitedUntil: a.state == .limited ? a.limitedUntil?.timeIntervalSince1970.rounded() : nil,
                           working: a.sessions.filter(working).count)
        }
        // Keep the Mac's order (people learn where each account sits); when there are too many, keep the ones that matter.
        var kept = rows
        if rows.count > Self.maxAccounts {
            let rank: (Account) -> Int = { a in
                (a.state == .limited ? 1000 : 0) + (a.state == .working ? 500 : 0) + (a.state == .offline ? -500 : 0) + a.pressure
            }
            let keep = Set(rows.sorted { rank($0) > rank($1) }.prefix(Self.maxAccounts).map(\.id))
            kept = rows.filter { keep.contains($0.id) }
        }
        self.init(accounts: kept, hidden: rows.count - kept.count, prompts: snap.prompts.count,
                  working: snap.sessions.filter(working).count, updated: snap.at.timeIntervalSince1970.rounded())
    }

    /// "rashid@lajward.dev (Hamagan)" → ("lajward.dev", "Hamagan"): the user part is the same on every account.
    public static func split(_ name: String) -> (title: String, org: String?) {
        var title = name
        var org: String?
        if title.hasSuffix(")"), let open = title.lastIndex(of: "(") {
            org = String(title[title.index(after: open)..<title.index(before: title.endIndex)])
            title = String(title[..<open]).trimmingCharacters(in: .whitespaces)
        }
        if let at = title.firstIndex(of: "@") { title = String(title[title.index(after: at)...]) }
        return (title.isEmpty ? name : title, org)
    }
}
