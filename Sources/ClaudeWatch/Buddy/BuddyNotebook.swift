import AppKit
import SwiftUI
import WatchCore

/// "Notebook": everything the character has learned, newest first.
@MainActor
enum BuddyNotebookWindow {
    private static var window: NSWindow?

    static func show(_ ctl: BuddyController) {
        if window == nil {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 460, height: 560),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Buddy's notebook"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: BuddyNotebookView(ctl: ctl, brain: ctl.brain))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct BuddyNotebookView: View {
    @ObservedObject var ctl: BuddyController
    @ObservedObject var brain: BuddyBrain
    @ObservedObject private var prefs = BuddyPrefs.shared
    @State private var seen = Set<String>()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TimelineView(.animation) { tl in
                    BuddyView(style: prefs.style, mood: .sleeping, t: tl.date.timeIntervalSinceReferenceDate,
                              activity: brain.learning != nil ? .explore : .idle)
                        .frame(width: 64, height: 64)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(brain.name)'s notebook").font(.title3.bold())
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Learn now") { brain.learnNow() }.disabled(brain.learning != nil)
            }
            .padding(14)
            if let e = brain.lastRunError { Text(e).font(.caption).foregroundStyle(.orange).padding(.horizontal, 14).padding(.bottom, 6) }
            Divider()
            if brain.memory.learned.isEmpty {
                Spacer()
                Text("Nothing yet. \(brain.name) is still curious…").foregroundStyle(.secondary)
                Spacer()
            } else {
                List(brain.memory.learned) { f in card(f) }.listStyle(.inset)
            }
        }
        .frame(minWidth: 380, minHeight: 360)
        .onAppear { seen = Set(brain.unread.map(\.id)); brain.markAllRead() }
    }

    private var status: String {
        if let t = brain.learning { return "Looking into: \(t)" }
        let n = brain.memory.learnedToday(now: .now), max = brain.mindConfig.limits.maxLearnsPerDay
        return brain.mindConfig.enabled ? "Learned \(n) of up to \(max) things today" : "Learning is switched off (mind.json)"
    }

    private func card(_ f: BuddyFinding) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(f.topic).font(.headline)
                if seen.contains(f.id) { Text("NEW").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.orange)).foregroundStyle(.white) }
                Spacer()
                Text(f.at, style: .relative).font(.caption).foregroundStyle(.secondary)
            }
            Text(f.finding)
            if !f.tip.isEmpty { Label(f.tip, systemImage: "lightbulb").font(.callout).foregroundStyle(.secondary) }
            if let u = URL(string: f.source), !f.source.isEmpty { Link(u.host ?? f.source, destination: u).font(.caption) }
        }
        .padding(.vertical, 5)
    }
}
