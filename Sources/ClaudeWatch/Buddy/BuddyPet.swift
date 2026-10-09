import AppKit
import SwiftUI
import WatchCore

/// The character on the screen: a small transparent panel above the Dock. It stays on every Space,
/// can be dragged, and strolls along the bottom while agents work.
@MainActor
final class BuddyPet {
    private unowned let ctl: BuddyController
    private var panel: NSPanel?
    private var timer: Timer?
    private var home = CGPoint.zero
    private var phase = 0.0
    private var offset: CGFloat = 0
    let walk = PetWalk()
    static let size = CGSize(width: 260, height: 320)   // room for the biggest pet and bubble
    /// The panel hugs the pet and bubble so its transparent part doesn't block clicks.
    private var wanted: CGSize {
        CGSize(width: max(210, 112 * ctl.prefs.scale + 50), height: 112 * ctl.prefs.scale + (ctl.bubble != nil ? 66 : 6))
    }

    init(_ ctl: BuddyController) { self.ctl = ctl }

    func setVisible(_ on: Bool) {
        if on { show() } else { hide() }
    }

    private func show() {
        if panel == nil { build() }
        panel?.orderFrontRegardless()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.step() }
            }
        }
    }

    private func hide() {
        timer?.invalidate(); timer = nil
        panel?.orderOut(nil)
    }

    private func build() {
        let p = NSPanel(contentRect: CGRect(origin: .zero, size: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        let host = NSHostingView(rootView: BuddyPetView(ctl: ctl, walk: walk))
        host.frame = CGRect(origin: .zero, size: Self.size)
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        panel = p
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let x = ctl.prefs.petHomeX ?? vf.maxX - Self.size.width - 90
        home = CGPoint(x: min(max(x, vf.minX), vf.maxX - Self.size.width), y: vf.minY - 4)
        p.setFrameOrigin(home)
    }

    private func step() {
        guard let p = panel else { return }
        let vf = (p.screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        if NSEvent.pressedMouseButtons & 1 != 0, p.frame.contains(NSEvent.mouseLocation) {
            // The user is dragging: wherever it lands becomes home.
            home = p.frame.origin; offset = 0
            ctl.prefs.petHomeX = home.x
            return
        }
        if ctl.mood == .busy, ctl.prefs.walks {
            phase += (1 / 30) * 0.7 * ctl.speed
            let reach = min(150, max(0, min(home.x - vf.minX, vf.maxX - wanted.width - home.x)) + 40)
            let target = CGFloat(sin(phase)) * reach
            walk.facingLeft = cos(phase) < 0
            offset += (target - offset) * 0.25
        } else {
            offset *= 0.9
            if abs(offset) < 0.3 { offset = 0 }
        }
        let size = wanted
        let x = min(max(home.x + offset, vf.minX), vf.maxX - size.width)
        let y = max(home.y, vf.minY - 4)
        let f = CGRect(x: x, y: y, width: size.width, height: size.height)
        if abs(p.frame.minX - f.minX) > 0.1 || abs(p.frame.minY - f.minY) > 0.1 || p.frame.size != size { p.setFrame(f, display: true) }
    }
}

final class PetWalk: ObservableObject {
    @Published var facingLeft = false
}

struct BuddyPetView: View {
    @ObservedObject var ctl: BuddyController
    @ObservedObject var walk: PetWalk
    @ObservedObject private var prefs = BuddyPrefs.shared
    @State private var hover = false
    var side: CGFloat { 112 * prefs.scale }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if let b = ctl.bubble {
                BubbleView(title: b.title, subtitle: b.subtitle, color: BuddyPalette.accent(ctl.mood))
                    .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
            }
            TimelineView(.animation) { tl in
                BuddyView(style: prefs.style, mood: ctl.mood, t: tl.date.timeIntervalSinceReferenceDate,
                          speed: ctl.speed, facingLeft: walk.facingLeft)
                    .frame(width: side, height: side)
                    .scaleEffect(hover ? 1.08 : 1, anchor: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: ctl.bubble?.title)
        .animation(.easeOut(duration: 0.15), value: hover)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { ctl.clicked() }
        .contextMenu { BuddyMenuContent(ctl: ctl) }
    }
}

struct BubbleView: View {
    var title: String, subtitle: String, color: Color
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .bold, design: .rounded)).lineLimit(1)
                Text(subtitle).font(.system(size: 10, weight: .medium, design: .rounded)).opacity(0.85).lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .frame(maxWidth: 190)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(color.gradient))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            Triangle().fill(color).frame(width: 14, height: 7)
        }
        .padding(.bottom, 2)
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(); p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY)); p.closeSubpath(); return p
    }
}

/// The right-click menu: every chat by state, then the buddy's own switches.
struct BuddyMenuContent: View {
    @ObservedObject var ctl: BuddyController
    var body: some View {
        let s = ctl.state
        if s.recent.isEmpty { Text("No chats yet") }
        ForEach(s.recent.prefix(10)) { c in
            Button("\(Self.mark(c.kind))  \(c.title)  ·  \(c.reason)") { ctl.open(c) }
        }
        Divider()
        Picker("Character", selection: Binding(get: { ctl.prefs.style }, set: { ctl.prefs.style = $0 })) {
            ForEach(BuddyStyle.allCases) { Text($0.title).tag($0) }
        }
        Button("Open Session Watch") { ctl.showApp() }
        Button("Hide buddy") { ctl.prefs.showPet = false }
    }
    static func mark(_ k: BuddyChat.Kind) -> String {
        switch k { case .needsYou: "🙋"; case .error: "⚠️"; case .working: "⚙️"; case .idle: "💤" }
    }
}
