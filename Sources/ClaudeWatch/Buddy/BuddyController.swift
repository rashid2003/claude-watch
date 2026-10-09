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
    private lazy var pet = BuddyPet(self)
    private lazy var dock = BuddyDock(self)
    private lazy var menuBar = BuddyMenuBar(self)

    /// What to draw: a previewed mood wins over the real one.
    var mood: BuddyMood {
        if let p = prefs.preview { return p }
        return state.mood == .celebrating && !prefs.celebrates ? .sleeping : state.mood
    }
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
        apply()
    }

    private func refresh() {
        let s = tracker.update(snapshot)
        if s != state { state = s }
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
        if let c = state.urgent, state.mood != .sleeping { open(c) } else { model?.showMain(.chats) }
    }

    func showApp() { model?.showMain() }

    /// The speech bubble text, or nil when the buddy has nothing to say.
    var bubble: (title: String, subtitle: String)? {
        guard prefs.showBubble else { return nil }
        let more = state.needsYou.count > 1 ? " (+\(state.needsYou.count - 1) more)" : ""
        switch mood {
        case .needsYou:
            guard let c = state.urgent, state.mood == .needsYou else { return ("Needs you!", "Preview") }
            return (c.title + more, c.reason)
        case .error:
            guard let c = state.urgent, state.mood == .error else { return ("Something broke", "Preview") }
            return (c.title, c.reason)
        case .celebrating:
            guard let c = state.urgent, state.mood == .celebrating else { return ("All done!", "Preview") }
            return (c.title, "Finished")
        default: return nil
        }
    }
}
