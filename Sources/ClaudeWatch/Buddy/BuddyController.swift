import AppKit
import Combine
import SwiftUI
import WatchCore

/// Owns the buddy: follows the app's snapshots, works out the mood, and keeps the three places
/// (screen pet, Dock tile, menu bar item) in step with the settings.
@MainActor
final class BuddyController: ObservableObject {
    static let shared = BuddyController()

    @Published private(set) var state = BuddyState.asleep
    let prefs = BuddyPrefs.shared
    private(set) var model: WatchModel?
    private var tracker = BuddyTracker()
    private var snapshot: Snapshot?
    private var bag = Set<AnyCancellable>()
    private var tick: Timer?
    private(set) lazy var brain = BuddyBrain(prefs.style)
    private var quietSince = Date()
    private var lastMood = BuddyMood.sleeping
    private lazy var pet = BuddyPet(self)
    private lazy var dock = BuddyDock(self)
    private lazy var menuBar = BuddyMenuBar(self)

    /// What to draw: a previewed mood wins over the real one.
    var mood: BuddyMood {
        if let p = prefs.preview { return p }
        if prefs.previewActivity != nil { return .sleeping }
        return state.mood == .celebrating && !prefs.celebrates ? .sleeping : state.mood
    }
    /// What the buddy does while nothing needs it. Right after the chats go quiet it just hangs around.
    var activity: BuddyActivity {
        if let a = prefs.previewActivity { return a }
        guard prefs.lifeEnabled else { return .sleep }
        if brain.announcement != nil { return .excited }
        if Date().timeIntervalSince(quietSince) < Double(brain.lifeConfig.idleSecondsBeforeLife) { return .idle }
        return brain.life.activity
    }
    /// The food being eaten.
    var food: String { brain.life.activity == .eat ? (brain.life.detail ?? "🍪") : "🍪" }
    /// How lively the busy walk is: more chats working, faster legs.
    var speed: Double { min(1.8, 1 + 0.2 * Double(max(0, state.working.count - 1))) }

    func start(_ model: WatchModel) {
        guard self.model == nil else { return }
        self.model = model
        model.$snapshot.receive(on: DispatchQueue.main).sink { [weak self] s in
            self?.snapshot = s
            self?.refresh()
        }.store(in: &bag)
        prefs.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            // Settings change after the publisher fires; apply on the next turn.
            DispatchQueue.main.async { self?.apply() }
        }.store(in: &bag)
        // Lets the celebration end by itself.
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        prefs.$style.receive(on: DispatchQueue.main).sink { [weak self] s in
            self?.brain.switchTo(s); self?.objectWillChange.send()
        }.store(in: &bag)
        brain.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        apply()
    }

    private func refresh() {
        let s = tracker.update(snapshot)
        if s != state { state = s }
        if s.mood != .sleeping { quietSince = Date() } else if lastMood != .sleeping { quietSince = Date() }
        lastMood = s.mood
        if prefs.lifeEnabled { brain.tick() }
        dock.update()
        menuBar.update()
    }

    private func apply() {
        pet.setVisible(prefs.showPet)
        dock.setEnabled(prefs.showDock)
        menuBar.setEnabled(prefs.showMenuBar)
        objectWillChange.send()
    }

    func open(_ chat: BuddyChat) {
        guard let model else { return }
        BuddyOpen.open(chat, model: model)
    }

    /// Click on the buddy: the chat that needs attention, else the one working, else the app.
    func clicked() {
        if let c = state.urgent, state.mood != .sleeping { open(c) }
        else if prefs.lifeEnabled, !brain.unread.isEmpty || brain.announcement != nil { showNotebook() }
        else { model?.showMain(.chats) }
    }

    func showApp() { model?.showMain() }

    struct Bubble: Equatable { var title: String; var subtitle: String; var color: Color }

    /// The speech bubble, or nil when the buddy has nothing to say. Chats come first, then what it learned,
    /// then a short caption of what it just started doing.
    var bubble: Bubble? {
        guard prefs.showBubble else { return nil }
        let more = state.needsYou.count > 1 ? " (+\(state.needsYou.count - 1) more)" : ""
        let color = BuddyPalette.accent(mood)
        switch mood {
        case .needsYou:
            guard let c = state.urgent, state.mood == .needsYou else { return Bubble(title: "Needs you!", subtitle: "Preview", color: color) }
            return Bubble(title: c.title + more, subtitle: c.reason, color: color)
        case .error:
            guard let c = state.urgent, state.mood == .error else { return Bubble(title: "Something broke", subtitle: "Preview", color: color) }
            return Bubble(title: c.title, subtitle: c.reason, color: color)
        case .celebrating:
            guard let c = state.urgent, state.mood == .celebrating else { return Bubble(title: "All done!", subtitle: "Preview", color: color) }
            return Bubble(title: c.title, subtitle: "Finished", color: color)
        case .busy: return nil
        case .sleeping:
            guard prefs.lifeEnabled else { return nil }
            if let f = brain.announcement { return Bubble(title: "💡 Guess what I learned!", subtitle: f.finding, color: BuddyPalette.accent(.celebrating)) }
            let l = brain.life
            if prefs.previewActivity == nil, Date().timeIntervalSince(l.startedAt) < 6, l.activity != .idle,
               Date().timeIntervalSince(quietSince) >= Double(brain.lifeConfig.idleSecondsBeforeLife) {
                let text = brain.learning.map { "Looking into: \($0)" } ?? l.caption
                return text.isEmpty ? nil : Bubble(title: text, subtitle: "", color: Color(red: 0.4, green: 0.5, blue: 0.85))
            }
            return nil
        }
    }

    var unreadCount: Int { brain.unread.count }

    func showNotebook() { BuddyNotebookWindow.show(self) }
}
