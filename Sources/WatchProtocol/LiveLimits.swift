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
    public var updated: Double

    public init(accounts: [Account], hidden: Int = 0, prompts: Int = 0, working: Int = 0, updated: Double) {
        self.accounts = accounts; self.hidden = hidden; self.prompts = prompts; self.working = working; self.updated = updated
    }

    public var updatedDate: Date { Date(timeIntervalSince1970: updated) }

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
