import Foundation
import WatchProtocol

/// A character's own life, read from `buddy/<character>/life.json` so anyone can edit it.
/// Every field is optional in the file; a missing one keeps its default.
public struct BuddyLifeConfig: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var activity: BuddyActivity
        public var weight: Double
        /// How long one go lasts: [min, max] seconds.
        public var seconds: [Int]
        /// Only during these local hours: [from, to) (22…7 wraps midnight). Missing means any time.
        public var hours: [Int]?

        public init(_ activity: BuddyActivity, weight: Double, seconds: [Int], hours: [Int]? = nil) {
            self.activity = activity; self.weight = weight; self.seconds = seconds; self.hours = hours
        }
        enum CodingKeys: String, CodingKey { case activity, weight, seconds, hours }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            activity = try c.decode(BuddyActivity.self, forKey: .activity)
            weight = try c.decodeIfPresent(Double.self, forKey: .weight) ?? 1
            seconds = try c.decodeIfPresent([Int].self, forKey: .seconds) ?? [40, 90]
            hours = try c.decodeIfPresent([Int].self, forKey: .hours)
        }
    }

    public var name: String
    /// Seconds the chats must stay quiet before the buddy starts living its own life.
    public var idleSecondsBeforeLife: Int
    public var routine: [Entry]
    public var movies: [String]
    public var foods: [String]

    public init(name: String = "Buddy", idleSecondsBeforeLife: Int = 10, routine: [Entry], movies: [String], foods: [String]) {
        self.name = name; self.idleSecondsBeforeLife = idleSecondsBeforeLife
        self.routine = routine; self.movies = movies; self.foods = foods
    }

    enum CodingKeys: String, CodingKey { case name, idleSecondsBeforeLife, routine, movies, foods }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let base = Self.defaults(for: nil)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? base.name
        idleSecondsBeforeLife = try c.decodeIfPresent(Int.self, forKey: .idleSecondsBeforeLife) ?? base.idleSecondsBeforeLife
        routine = try c.decodeIfPresent([Entry].self, forKey: .routine) ?? base.routine
        movies = try c.decodeIfPresent([String].self, forKey: .movies) ?? base.movies
        foods = try c.decodeIfPresent([String].self, forKey: .foods) ?? base.foods
    }

    static let night = [22, 7]
    public static func defaults(for style: String?) -> BuddyLifeConfig {
        var routine: [Entry] = [
            Entry(.idle, weight: 3, seconds: [20, 50]),
            Entry(.eat, weight: 2, seconds: [25, 45], hours: [7, 23]),
            Entry(.movie, weight: 2, seconds: [60, 120], hours: [15, 24]),
            Entry(.explore, weight: 2, seconds: [30, 70]),
            Entry(.read, weight: 1.5, seconds: [40, 80]),
            Entry(.dance, weight: 1, seconds: [15, 30], hours: [8, 23]),
            Entry(.stretch, weight: 1, seconds: [10, 18]),
            Entry(.sleep, weight: 10, seconds: [120, 300], hours: night),
            Entry(.sleep, weight: 1.5, seconds: [40, 90], hours: [13, 16]),
        ]
        switch style {
        case "pixel":
            routine[2].weight = 3   // a gamer: more screen time
            return BuddyLifeConfig(name: "Pixel", routine: routine,
                                   movies: ["Tron", "Wreck-It Ralph", "Scott Pilgrim vs. the World", "Ready Player One"],
                                   foods: ["🍕", "🍔", "🍟", "🌮"])
        case "bot":
            routine[3].weight = 3   // loves finding things out
            return BuddyLifeConfig(name: "Bolt", routine: routine,
                                   movies: ["WALL·E", "Big Hero 6", "The Iron Giant", "Interstellar"],
                                   foods: ["🔋", "🍬", "🍎", "🥨"])
        default:
            return BuddyLifeConfig(name: "Blobby", routine: routine,
                                   movies: ["Spirited Away", "My Neighbor Totoro", "Finding Nemo", "Paddington 2"],
                                   foods: ["🍪", "🍓", "🍩", "🍙"])
        }
    }
}

/// What the buddy is doing with its time.
public struct BuddyLifeState: Equatable, Sendable {
    public var activity: BuddyActivity
    public var startedAt: Date
    public var endsAt: Date
    /// The movie being watched or the food being eaten.
    public var detail: String?

    public init(activity: BuddyActivity, startedAt: Date, endsAt: Date, detail: String?) {
        self.activity = activity; self.startedAt = startedAt; self.endsAt = endsAt; self.detail = detail
    }

    /// A short line for a speech bubble when the activity starts.
    public var caption: String {
        switch activity {
        case .idle: ""
        case .sleep: "Zzz…"
        case .eat: "Snack time \(detail ?? "")"
        case .movie: detail.map { "Movie time: \($0)" } ?? "Movie time"
        case .explore: "Let's explore…"
        case .read: "Reading a good book"
        case .dance: "♪ Dance time ♪"
        case .stretch: "Big stretch"
        case .excited: "I found something!"
        }
    }
}

public protocol BuddyRandom { mutating func unit() -> Double }
public struct SystemBuddyRandom: BuddyRandom {
    public init() {}
    public mutating func unit() -> Double { Double.random(in: 0..<1) }
}

public enum BuddyLife {
    /// Whether local `hour` (0…23) falls in [from, to); wraps midnight when from > to.
    public static func inHours(_ hour: Int, _ range: [Int]?) -> Bool {
        guard let r = range, r.count == 2 else { return true }
        let (a, b) = (r[0], r[1])
        if a == b { return true }
        return a < b ? (hour >= a && hour < b) : (hour >= a || hour < b)
    }

    /// The next thing to do at `now`: a weighted pick among the routine entries allowed this hour.
    public static func pick(_ cfg: BuddyLifeConfig, now: Date, calendar: Calendar = .current,
                            avoiding last: BuddyActivity? = nil, rng: inout some BuddyRandom) -> BuddyLifeState {
        let hour = calendar.component(.hour, from: now)
        var entries = cfg.routine.filter { $0.weight > 0 && inHours(hour, $0.hours) }
        if entries.count > 1, let last { entries = entries.filter { $0.activity != last || entries.allSatisfy { $0.activity == last } } }
        guard !entries.isEmpty else {
            return BuddyLifeState(activity: .idle, startedAt: now, endsAt: now.addingTimeInterval(30), detail: nil)
        }
        let total = entries.reduce(0) { $0 + $1.weight }
        var roll = rng.unit() * total
        var chosen = entries[0]
        for e in entries { roll -= e.weight; if roll < 0 { chosen = e; break } }
        let lo = max(5, chosen.seconds.first ?? 40), hi = max(lo, chosen.seconds.count > 1 ? chosen.seconds[1] : lo)
        let secs = Double(lo) + rng.unit() * Double(hi - lo)
        var detail: String?
        switch chosen.activity {
        case .movie: detail = cfg.movies.isEmpty ? nil : cfg.movies[Int(rng.unit() * Double(cfg.movies.count)) % cfg.movies.count]
        case .eat: detail = cfg.foods.isEmpty ? nil : cfg.foods[Int(rng.unit() * Double(cfg.foods.count)) % cfg.foods.count]
        default: break
        }
        return BuddyLifeState(activity: chosen.activity, startedAt: now, endsAt: now.addingTimeInterval(secs), detail: detail)
    }
}
