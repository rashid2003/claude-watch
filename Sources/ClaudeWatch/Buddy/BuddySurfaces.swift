import AppKit
import SwiftUI
import WatchCore

// MARK: - Dock tile

/// The app's Dock icon, replaced by the live buddy.
@MainActor
final class BuddyDock {
    private unowned let ctl: BuddyController
    private var enabled = false
    private var timer: Timer?
    private var host: NSHostingView<DockBuddyView>?

    init(_ ctl: BuddyController) { self.ctl = ctl }

    func setEnabled(_ on: Bool) {
        enabled = on
        timer?.invalidate(); timer = nil
        let tile = NSApp.dockTile
        guard on else { tile.contentView = nil; tile.badgeLabel = nil; tile.display(); return }
        let h = NSHostingView(rootView: view())
        h.frame = CGRect(origin: .zero, size: tile.size)
        tile.contentView = h
        host = h
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.redraw() }
        }
        update()
    }

    private func view() -> DockBuddyView {
        DockBuddyView(style: ctl.prefs.style, mood: ctl.mood, t: Date.timeIntervalSinceReferenceDate, speed: ctl.speed)
    }

    private func redraw() {
        guard enabled, let host else { return }
        host.rootView = view()
        NSApp.dockTile.display()
    }

    func update() {
        guard enabled else { return }
        let n = ctl.state.needsYou.count + ctl.state.errors.count
        NSApp.dockTile.badgeLabel = n > 0 ? String(n) : nil
    }
}

struct DockBuddyView: View {
    var style: BuddyStyle, mood: BuddyMood, t: Double, speed: Double
    var body: some View {
        let c = BuddyPalette.accent(mood)
        ZStack {
            RoundedRectangle(cornerRadius: 96, style: .continuous)
                .fill(LinearGradient(colors: [c.opacity(0.95), c.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                .padding(8)
            BuddyView(style: style, mood: mood, t: t, speed: speed).padding(14)
        }
    }
}

// MARK: - Menu bar

/// A small animated face in the menu bar; clicking lists every chat by state.
@MainActor
final class BuddyMenuBar: NSObject, NSMenuDelegate {
    private unowned let ctl: BuddyController
    private var item: NSStatusItem?
    private var timer: Timer?
    private var lastKey = ""

    init(_ ctl: BuddyController) { self.ctl = ctl }

    func setEnabled(_ on: Bool) {
        timer?.invalidate(); timer = nil
        guard on else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil; return
        }
        if item == nil {
            let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let m = NSMenu(); m.delegate = self
            i.menu = m
            item = i
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.redraw() }
        }
        update()
    }

    func update() {
        guard item != nil else { return }
        item?.button?.toolTip = "Session Watch · \(ctl.mood.title)"
        let n = ctl.state.needsYou.count
        item?.button?.title = n > 0 ? " \(n)" : ""
        item?.button?.imagePosition = n > 0 ? .imageLeading : .imageOnly
        redraw()
    }

    private func redraw() {
        guard let button = item?.button else { return }
        // Sleeping barely moves: redraw it rarely.
        let t = Date.timeIntervalSinceReferenceDate
        let r = ImageRenderer(content: BuddyView(style: ctl.prefs.style, mood: ctl.mood, t: t, speed: ctl.speed)
            .frame(width: 22, height: 22))
        r.scale = NSScreen.main?.backingScaleFactor ?? 2
        if let img = r.nsImage { img.isTemplate = false; button.image = img }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let head = NSMenuItem(title: ctl.mood.title, action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        let s = ctl.state
        for (title, chats) in [("Needs you", s.needsYou), ("Errors", s.errors), ("Working", s.working)] where !chats.isEmpty {
            menu.addItem(.separator())
            let h = NSMenuItem(title: title, action: nil, keyEquivalent: ""); h.isEnabled = false
            menu.addItem(h)
            for c in chats.prefix(8) { menu.addItem(chatItem(c)) }
        }
        let idle = s.recent.filter { $0.kind == .idle }.prefix(5)
        if !idle.isEmpty {
            menu.addItem(.separator())
            let h = NSMenuItem(title: "Recent", action: nil, keyEquivalent: ""); h.isEnabled = false
            menu.addItem(h)
            for c in idle { menu.addItem(chatItem(c)) }
        }
        menu.addItem(.separator())
        let app = NSMenuItem(title: "Open Session Watch", action: #selector(openApp), keyEquivalent: "")
        app.target = self
        menu.addItem(app)
    }

    private func chatItem(_ c: BuddyChat) -> NSMenuItem {
        let i = NSMenuItem(title: "\(c.title) — \(c.reason)", action: #selector(openChat(_:)), keyEquivalent: "")
        i.target = self
        i.representedObject = c.id
        i.indentationLevel = 1
        return i
    }

    @objc private func openChat(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let c = ctl.state.recent.first(where: { $0.id == id }) else { return }
        ctl.open(c)
    }

    @objc private func openApp() { ctl.showApp() }
}
