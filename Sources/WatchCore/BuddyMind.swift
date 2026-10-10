import Foundation
import WatchProtocol

/// A character's own mind, read from `buddy/<character>/mind.json`. It can only search the web and learn.
public struct BuddyMindConfig: Codable, Equatable, Sendable {
    public struct Follow: Codable, Equatable, Sendable {
        public var topic: String
        /// How often to look for news on it.
        public var everyHours: Double
        /// "always" tells you each time there is news; "interesting" only when it's rated interesting enough.
        public var tell: String
        public init(topic: String, everyHours: Double = 24, tell: String = "always") {
            self.topic = topic; self.everyHours = everyHours; self.tell = tell
        }
        enum CodingKeys: String, CodingKey { case topic, everyHours, tell }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            topic = try c.decode(String.self, forKey: .topic)
            everyHours = try c.decodeIfPresent(Double.self, forKey: .everyHours) ?? 24
            tell = try c.decodeIfPresent(String.self, forKey: .tell) ?? "always"
        }
    }
    public struct Limits: Codable, Equatable, Sendable {
        public var maxLearnsPerDay = 6
        public var minMinutesBetween = 45
        public var maxTellsPerDay = 5
        /// No searching and no telling during these local hours: [from, to).
        public var quietHours = [22, 8]
        public init() {}
        enum CodingKeys: String, CodingKey { case maxLearnsPerDay, minMinutesBetween, maxTellsPerDay, quietHours }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            let b = Limits()
            maxLearnsPerDay = try c.decodeIfPresent(Int.self, forKey: .maxLearnsPerDay) ?? b.maxLearnsPerDay
            minMinutesBetween = try c.decodeIfPresent(Int.self, forKey: .minMinutesBetween) ?? b.minMinutesBetween
            maxTellsPerDay = try c.decodeIfPresent(Int.self, forKey: .maxTellsPerDay) ?? b.maxTellsPerDay
            quietHours = try c.decodeIfPresent([Int].self, forKey: .quietHours) ?? b.quietHours
        }
    }

    public var enabled: Bool
    public var personality: String
    public var language: String
    /// The Claude model it thinks with ("haiku" is cheap and quick).
    public var model: String
    public var interests: [String]
    public var follows: [Follow]
    public var limits: Limits
    /// Stop a single search that would cost more than this many dollars.
    public var maxBudgetUSD: Double
    /// Findings rated below this (1–5) are saved in the notebook but not announced.
    public var minInterest: Int
    /// Which Claude login to use: the folder of another account (e.g. "~/.claude-2"). Missing = your default.
    public var claudeConfigDir: String?

    public init(enabled: Bool = true, personality: String, language: String = "English", model: String = "haiku",
                interests: [String], follows: [Follow], limits: Limits = Limits(), maxBudgetUSD: Double = 0.15,
                minInterest: Int = 3, claudeConfigDir: String? = nil) {
        self.enabled = enabled; self.personality = personality; self.language = language; self.model = model
        self.interests = interests; self.follows = follows; self.limits = limits; self.maxBudgetUSD = maxBudgetUSD
        self.minInterest = minInterest; self.claudeConfigDir = claudeConfigDir
    }

    enum CodingKeys: String, CodingKey {
        case enabled, personality, language, model, interests, follows, limits, maxBudgetUSD, minInterest, claudeConfigDir
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let b = Self.defaults(for: nil)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? b.enabled
        personality = try c.decodeIfPresent(String.self, forKey: .personality) ?? b.personality
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? b.language
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? b.model
        interests = try c.decodeIfPresent([String].self, forKey: .interests) ?? b.interests
        follows = try c.decodeIfPresent([Follow].self, forKey: .follows) ?? b.follows
        limits = try c.decodeIfPresent(Limits.self, forKey: .limits) ?? b.limits
        maxBudgetUSD = try c.decodeIfPresent(Double.self, forKey: .maxBudgetUSD) ?? b.maxBudgetUSD
        minInterest = try c.decodeIfPresent(Int.self, forKey: .minInterest) ?? b.minInterest
        claudeConfigDir = try c.decodeIfPresent(String.self, forKey: .claudeConfigDir)
    }

    public static func defaults(for style: String?) -> BuddyMindConfig {
        let movies = Follow(topic: "new movie releases, trailers and movie news this week", everyHours: 24, tell: "always")
        switch style {
        case "pixel":
            return BuddyMindConfig(personality: "Pixel is a retro-gaming critter: excitable, loves high scores, says things like \"Level up!\". Speaks like a happy kid.",
                                   interests: ["retro video games", "pixel art", "chiptune music", "indie games"],
                                   follows: [Follow(topic: "new video game releases and announcements", everyHours: 24, tell: "interesting"), movies])
        case "bot":
            return BuddyMindConfig(personality: "Bolt is a tidy, gentle little robot: precise, wonders about how things work, says \"Fascinating!\". Speaks like a happy kid.",
                                   interests: ["robots", "gadgets and how they work", "space exploration", "AI news"],
                                   follows: [Follow(topic: "AI and robotics news", everyHours: 24, tell: "interesting"), movies])
        default:
            return BuddyMindConfig(personality: "Blobby is a soft, curious blob: easily amazed, loves animals and strange facts, says \"Guess what!\". Speaks like a happy kid telling their parents.",
                                   interests: ["octopuses and the deep sea", "space and planets", "cute animals", "how everyday things are made"],
                                   follows: [movies])
        }
    }
}

/// One thing the character learned.
public struct BuddyFinding: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var at: Date
    public var topic: String
    public var finding: String
    public var tip: String
    public var source: String
    public var interest: Int
    public var isFollow: Bool
    public var told: Bool
    public var read: Bool
}

/// What the character remembers: kept in `buddy/<character>/memory.json`.
public struct BuddyMemory: Codable, Equatable, Sendable {
    public var learned: [BuddyFinding] = []
    /// When each followed topic was last checked.
    public var followChecks: [String: Date] = [:]
    /// Interests it picked up by itself.
    public var discovered: [String] = []
    public var lastLearnAt: Date?
    public init() {}
    enum CodingKeys: String, CodingKey { case learned, followChecks, discovered, lastLearnAt }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        learned = try c.decodeIfPresent([BuddyFinding].self, forKey: .learned) ?? []
        followChecks = try c.decodeIfPresent([String: Date].self, forKey: .followChecks) ?? [:]
        discovered = try c.decodeIfPresent([String].self, forKey: .discovered) ?? []
        lastLearnAt = try c.decodeIfPresent(Date.self, forKey: .lastLearnAt)
    }

    public static let keep = 200
    public mutating func add(_ f: BuddyFinding) {
        learned.insert(f, at: 0)
        if learned.count > Self.keep { learned.removeLast(learned.count - Self.keep) }
    }
    public func learnedToday(now: Date, calendar: Calendar = .current) -> Int {
        learned.filter { calendar.isDate($0.at, inSameDayAs: now) }.count
    }
    public func toldToday(now: Date, calendar: Calendar = .current) -> Int {
        learned.filter { $0.told && calendar.isDate($0.at, inSameDayAs: now) }.count
    }
    public var unread: [BuddyFinding] { learned.filter { !$0.read } }
}

/// What to search next.
public struct BuddyPlan: Equatable, Sendable {
    public var topic: String
    public var follow: BuddyMindConfig.Follow?
}

public enum BuddyMind {
    /// Picks the next thing to look up, or nil when it's not the time (disabled, quiet hours, too soon,
    /// enough for today, nothing to be curious about).
    public static func plan(_ cfg: BuddyMindConfig, memory: BuddyMemory, now: Date, calendar: Calendar = .current,
                            ignoringPause: Bool = false, rng: inout some BuddyRandom) -> BuddyPlan? {
        guard cfg.enabled else { return nil }
        let hour = calendar.component(.hour, from: now)
        if BuddyLife.inHours(hour, cfg.limits.quietHours) { return nil }
        if memory.learnedToday(now: now, calendar: calendar) >= cfg.limits.maxLearnsPerDay { return nil }
        if !ignoringPause, let last = memory.lastLearnAt,
           now.timeIntervalSince(last) < Double(cfg.limits.minMinutesBetween) * 60 { return nil }
        // News on followed topics comes first, once they are due.
        for f in cfg.follows {
            let due = memory.followChecks[f.topic].map { now.timeIntervalSince($0) >= f.everyHours * 3600 } ?? true
            if due { return BuddyPlan(topic: f.topic, follow: f) }
        }
        let topics = cfg.interests + memory.discovered
        guard !topics.isEmpty else { return nil }
        // Favour what it has learned the least about.
        let counts = topics.map { t in memory.learned.filter { $0.topic.lowercased().contains(t.lowercased()) }.count }
        let weights = counts.map { 1 / Double($0 + 1) }
        var roll = rng.unit() * weights.reduce(0, +)
        for (i, w) in weights.enumerated() { roll -= w; if roll < 0 { return BuddyPlan(topic: topics[i], follow: nil) } }
        return BuddyPlan(topic: topics[0], follow: nil)
    }

    public static func inQuietHours(_ cfg: BuddyMindConfig, now: Date, calendar: Calendar = .current) -> Bool {
        BuddyLife.inHours(calendar.component(.hour, from: now), cfg.limits.quietHours)
    }

    public static func prompt(name: String, cfg: BuddyMindConfig, plan: BuddyPlan, memory: BuddyMemory, now: Date) -> String {
        let recent = memory.learned.prefix(12).map { "- \($0.topic): \($0.finding)" }.joined(separator: "\n")
        var p = """
        You are \(name), a small character who lives on someone's Mac and loves to learn. \(cfg.personality)
        Write in \(cfg.language). You tell what you learn to your human like a happy child telling a parent.

        Your job right now: use WebSearch (and WebFetch if needed) to learn something real and recent about: "\(plan.topic)".
        """
        if plan.follow != nil {
            let since = ISO8601DateFormatter().string(from: memory.followChecks[plan.topic] ?? now.addingTimeInterval(-7 * 86400))
            p += "\nYou are following this topic: look for NEW news or releases since \(since). If there is nothing new, set \"new\" to false."
        }
        if !recent.isEmpty { p += "\n\nThings you already told your human (do not repeat them):\n\(recent)" }
        p += """


        You can only search and read the web. Do nothing else: no files, no commands, no messages.
        Reply with ONLY one JSON object, nothing before or after it:
        {"topic": "<short title of what you learned>",
         "finding": "<1-2 short sentences in your own voice>",
         "tip": "<one short useful tip or fun fact>",
         "source": "<url>",
         "interest": <1-5, how exciting this is>,
         "new": <true or false>,
         "nextInterests": ["<up to 2 new things you got curious about>"]}
        """
        return p
    }

    public struct Answer: Codable, Equatable, Sendable {
        public var topic: String
        public var finding: String
        public var tip: String?
        public var source: String?
        public var interest: Int?
        public var new: Bool?
        public var nextInterests: [String]?
    }

    /// The CLI's JSON envelope holds the model's text in `result`; that text should hold one JSON object.
    public static func parse(cliOutput: String) -> Answer? {
        var text = cliOutput
        if let data = cliOutput.data(using: .utf8),
           let env = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let r = env["result"] as? String {
            if (env["is_error"] as? Bool) == true { return nil }
            text = r
        }
        guard let obj = firstJSONObject(in: text), let data = obj.data(using: .utf8) else { return nil }
        guard let a = try? JSONDecoder().decode(Answer.self, from: data), !a.finding.isEmpty else { return nil }
        return a
    }

    /// The first balanced `{ … }` in `text` (the model may wrap it in a code fence).
    static func firstJSONObject(in text: String) -> String? {
        var depth = 0, start: String.Index?, inString = false, escaped = false
        for i in text.indices {
            let ch = text[i]
            if inString {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
                continue
            }
            if ch == "\"" { inString = true }
            else if ch == "{" { if depth == 0 { start = i }; depth += 1 }
            else if ch == "}" , depth > 0 {
                depth -= 1
                if depth == 0, let s = start { return String(text[s...i]) }
            }
        }
        return nil
    }

    /// Turns an answer into a finding, and says whether the character should announce it.
    public static func record(answer: Answer, cfg: BuddyMindConfig, memory: inout BuddyMemory,
                              plan: BuddyPlan, now: Date, calendar: Calendar = .current) -> BuddyFinding? {
        memory.lastLearnAt = now
        if let f = plan.follow { memory.followChecks[f.topic] = now }
        for n in (answer.nextInterests ?? []).prefix(2) {
            let t = n.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, !memory.discovered.contains(t), !cfg.interests.contains(t), memory.discovered.count < 30 { memory.discovered.append(t) }
        }
        if plan.follow != nil, answer.new == false { return nil }       // checked: nothing new
        let interest = min(5, max(1, answer.interest ?? 3))
        var announce: Bool
        switch plan.follow?.tell {
        case "always": announce = true
        default: announce = interest >= cfg.minInterest
        }
        if memory.toldToday(now: now, calendar: calendar) >= cfg.limits.maxTellsPerDay { announce = false }
        if inQuietHours(cfg, now: now, calendar: calendar) { announce = false }
        let f = BuddyFinding(id: UUID().uuidString, at: now, topic: answer.topic, finding: answer.finding, tip: answer.tip ?? "",
                             source: answer.source ?? "", interest: interest, isFollow: plan.follow != nil, told: announce, read: false)
        memory.add(f)
        return f
    }
}
