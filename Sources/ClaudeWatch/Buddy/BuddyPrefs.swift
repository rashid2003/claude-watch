import SwiftUI
import WatchCore

/// The buddy's settings. Kept in UserDefaults (not config.json) so they never touch the shared config.
final class BuddyPrefs: ObservableObject {
    static let shared = BuddyPrefs()
    private let d = UserDefaults.standard

    @Published var style: BuddyStyle { didSet { d.set(style.rawValue, forKey: "buddy.style") } }
    @Published var showPet: Bool { didSet { d.set(showPet, forKey: "buddy.pet") } }
    @Published var showDock: Bool { didSet { d.set(showDock, forKey: "buddy.dock") } }
    @Published var showMenuBar: Bool { didSet { d.set(showMenuBar, forKey: "buddy.menubar") } }
    /// Screen pet size: 0.7 (small) to 1.6 (large).
    @Published var scale: Double { didSet { d.set(scale, forKey: "buddy.scale") } }
    @Published var walks: Bool { didSet { d.set(walks, forKey: "buddy.walks") } }
    @Published var showBubble: Bool { didSet { d.set(showBubble, forKey: "buddy.bubble") } }
    @Published var celebrates: Bool { didSet { d.set(celebrates, forKey: "buddy.celebrate") } }
    /// Lets the buddy live its own life (eat, sleep, watch movies, explore) while no chat needs it.
    @Published var lifeEnabled: Bool { didSet { d.set(lifeEnabled, forKey: "buddy.life") } }
    /// Forces an activity so you can see it; not saved.
    @Published var previewActivity: BuddyActivity?
    /// Forces a mood so you can see each animation; nil follows the real chats. Not saved.
    @Published var preview: BuddyMood?

    var isAnythingOn: Bool { showPet || showDock || showMenuBar }

    private init() {
        style = BuddyStyle(rawValue: d.string(forKey: "buddy.style") ?? "") ?? .blobby
        showPet = d.object(forKey: "buddy.pet") as? Bool ?? true
        showDock = d.object(forKey: "buddy.dock") as? Bool ?? false
        showMenuBar = d.object(forKey: "buddy.menubar") as? Bool ?? false
        scale = d.object(forKey: "buddy.scale") as? Double ?? 1
        walks = d.object(forKey: "buddy.walks") as? Bool ?? true
        showBubble = d.object(forKey: "buddy.bubble") as? Bool ?? true
        celebrates = d.object(forKey: "buddy.celebrate") as? Bool ?? true
        lifeEnabled = d.object(forKey: "buddy.life") as? Bool ?? true
        #if DEBUG
        if let m = ProcessInfo.processInfo.environment["SW_BUDDY_MOOD"] { preview = BuddyMood(rawValue: m) }
        if let a = ProcessInfo.processInfo.environment["SW_BUDDY_ACTIVITY"] { previewActivity = BuddyActivity(rawValue: a) }
        if let s = ProcessInfo.processInfo.environment["SW_BUDDY_STYLE"], let st = BuddyStyle(rawValue: s) { style = st }
        #endif
    }

    /// Where the pet last rested (screen x of its left edge), if the user moved it.
    var petHomeX: CGFloat? {
        get { d.object(forKey: "buddy.homeX") as? CGFloat }
        set { d.set(newValue, forKey: "buddy.homeX") }
    }
}
