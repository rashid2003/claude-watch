import AppKit
import SwiftUI
import WatchCore

/// One character's life and mind: what it does with its spare time, and what it is learning.
/// Reads `life.json` / `mind.json` (editable, reloaded when they change) and keeps `memory.json`.
@MainActor
final class BuddyBrain: ObservableObject {
    @Published private(set) var life: BuddyLifeState
    @Published private(set) var lifeConfig: BuddyLifeConfig
    @Published private(set) var mindConfig: BuddyMindConfig
    @Published private(set) var memory = BuddyMemory()
    @Published private(set) var learning: String?          // the topic it is looking into right now
    @Published private(set) var announcement: BuddyFinding?
    @Published private(set) var fileErrors: [String] = []
    @Published private(set) var lastRunError: String?

    private(set) var character: BuddyStyle
    private(set) var files: BuddyFiles
    private var rng = SystemBuddyRandom()
    private var lifeModified: Date?, mindModified: Date?
    private var announceUntil = Date.distantPast
    private var nextCheck = Date.distantPast
    private var nextReload = Date.distantPast
    private var retryAfter = Date.distantPast
    private var lifeFromLearning = false
    static let announceSeconds: TimeInterval = 14

    init(_ style: BuddyStyle) {
        character = style
        files = BuddyFiles(character: style.rawValue)
        lifeConfig = .defaults(for: style.rawValue)
        mindConfig = .defaults(for: style.rawValue)
        life = BuddyLifeState(activity: .idle, startedAt: .now, endsAt: .now.addingTimeInterval(10), detail: nil)
        reload(force: true)
    }

    func switchTo(_ style: BuddyStyle) {
        guard style != character else { return }
        character = style
        files = BuddyFiles(character: style.rawValue)
        learning = nil; announcement = nil
        lifeConfig = .defaults(for: style.rawValue); mindConfig = .defaults(for: style.rawValue)
        reload(force: true)
        life = BuddyLifeState(activity: .idle, startedAt: .now, endsAt: .now, detail: nil)
    }

    var name: String { lifeConfig.name }
    var unread: [BuddyFinding] { memory.unread }

    // MARK: Files

    private func reload(force: Bool = false) {
        var errors: [String] = []
        if force || BuddyFiles.modified(files.life) != lifeModified {
            let l = files.load(files.life, fallback: BuddyLifeConfig.defaults(for: character.rawValue))
            lifeConfig = l.value; lifeModified = l.modified
            if let e = l.error { errors.append(e) }
        } else if let e = fileErrors.first(where: { $0.hasPrefix("life.json") }) { errors.append(e) }
        if force || BuddyFiles.modified(files.mind) != mindModified {
            let m = files.load(files.mind, fallback: BuddyMindConfig.defaults(for: character.rawValue))
            mindConfig = m.value; mindModified = m.modified
            if let e = m.error { errors.append(e) }
        } else if let e = fileErrors.first(where: { $0.hasPrefix("mind.json") }) { errors.append(e) }
        if force { memory = files.load(files.memory, fallback: BuddyMemory()).value }
        if errors != fileErrors { fileErrors = errors }
    }

    func setMindEnabled(_ on: Bool) {
        guard fileErrors.allSatisfy({ !$0.hasPrefix("mind.json") }) else { return }
        var c = mindConfig; c.enabled = on
        files.save(c, to: files.mind)
        mindConfig = c; mindModified = BuddyFiles.modified(files.mind)
    }

    func markAllRead() {
        guard !memory.unread.isEmpty else { return }
        for i in memory.learned.indices { memory.learned[i].read = true }
        files.save(memory, to: files.memory)
    }

    // MARK: Ticking

    /// Called every second.
    func tick(now: Date = Date()) {
        if now >= nextReload { reload(); nextReload = now.addingTimeInterval(4) }
        if announcement != nil, now >= announceUntil { announcement = nil }

        if announcement != nil {
            if life.activity != .excited { life = BuddyLifeState(activity: .excited, startedAt: now, endsAt: announceUntil, detail: nil) }
        } else if let topic = learning {
            if life.activity != .explore || life.detail != topic {
                life = BuddyLifeState(activity: .explore, startedAt: now, endsAt: now.addingTimeInterval(600), detail: topic)
                lifeFromLearning = true
            }
        } else if now >= life.endsAt || life.activity == .excited || lifeFromLearning {
            lifeFromLearning = false
            life = BuddyLife.pick(lifeConfig, now: now, avoiding: life.activity, rng: &rng)
        }

        if learning == nil, now >= nextCheck {
            nextCheck = now.addingTimeInterval(20)
            if now >= retryAfter, let plan = BuddyMind.plan(mindConfig, memory: memory, now: now, rng: &rng) { learn(plan) }
        }
    }

    /// "Learn something now": ignores the pause between searches, not the daily limit or quiet hours.
    func learnNow() {
        guard learning == nil else { return }
        let now = Date()
        guard let plan = BuddyMind.plan(mindConfig, memory: memory, now: now, ignoringPause: true, rng: &rng) else {
            lastRunError = mindConfig.enabled ? "Not now: it's quiet hours, today's limit is reached, or there is nothing to be curious about"
                                              : "Learning is switched off in mind.json"
            return
        }
        retryAfter = .distantPast
        learn(plan)
    }

    private func learn(_ plan: BuddyPlan) {
        learning = plan.topic
        lastRunError = nil
        let cfg = mindConfig, mem = memory, name = lifeConfig.name
        let prompt = BuddyMind.prompt(name: name, cfg: cfg, plan: plan, memory: mem, now: Date())
        Task.detached(priority: .utility) {
            let result = BuddyMindRunner.run(prompt: prompt, cfg: cfg)
            await MainActor.run { self.finish(plan, result) }
        }
    }

    private func finish(_ plan: BuddyPlan, _ result: Result<String, BuddyMindRunner.Failure>) {
        learning = nil
        let now = Date()
        switch result {
        case .failure(let f):
            retryAfter = now.addingTimeInterval(30 * 60)
            switch f {
            case .noCLI: lastRunError = "Couldn't find the claude command"
            case .timedOut: lastRunError = "The search took too long"
            case .failed(let why): lastRunError = "The search failed: \(why)"
            }
        case .success(let out):
            guard let answer = BuddyMind.parse(cliOutput: out) else {
                retryAfter = now.addingTimeInterval(30 * 60)
                lastRunError = "Couldn't understand what it found"
                return
            }
            let f = BuddyMind.record(answer: answer, cfg: mindConfig, memory: &memory, plan: plan, now: now)
            files.save(memory, to: files.memory)
            if let f, f.told {
                announcement = f
                announceUntil = now.addingTimeInterval(Self.announceSeconds)
            }
        }
    }

    func reveal() { NSWorkspace.shared.activateFileViewerSelecting([files.dir]) }
    func edit(_ url: URL) { NSWorkspace.shared.open(url) }
}
