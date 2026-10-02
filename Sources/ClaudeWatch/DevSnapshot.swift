#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: `kill -USR1 <pid>` writes a PNG of each visible window to $SW_SNAPSHOT_DIR
/// (UI checks without Screen Recording permission). Not compiled into release builds.
@MainActor
enum DevSnapshot {
    private static var source: DispatchSourceSignal?
    private static var commands: DispatchSourceSignal?

    static func install() {
        switch ProcessInfo.processInfo.environment["SW_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        guard let dir = ProcessInfo.processInfo.environment["SW_SNAPSHOT_DIR"] else { return }
        signal(SIGUSR1, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        s.setEventHandler { capture(to: URL(fileURLWithPath: dir)) }
        s.resume()
        source = s
        // `kill -USR2 <pid>` runs the lines of $SW_SNAPSHOT_DIR/commands through the same model
        // calls the UI makes, and writes the resulting state to $SW_SNAPSHOT_DIR/state.
        signal(SIGUSR2, SIG_IGN)
        let c = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        c.setEventHandler { run(dir: URL(fileURLWithPath: dir)) }
        c.resume()
        commands = c
    }

    static func run(dir: URL) {
        let model = WatchModel.shared
        let text = (try? String(contentsOf: dir.appendingPathComponent("commands"), encoding: .utf8)) ?? ""
        for line in text.split(separator: "\n") {
            let w = line.split(separator: " ").map(String.init)
            switch (w.first, w.count > 1 ? w[1] : "") {
            case ("section", let v): model.section = MainSection(rawValue: v)
            case ("dock", let v): model.setShowInDock(v == "on")
            case ("menubar", let v): model.setShowInMenuBar(v == "on")
            case ("delay", let v): if let d = Double(v) { model.updateConfig { $0.retryDelaySeconds = d } }
            case ("close", _): model.mainWindow?.performClose(nil)
            case ("popover", let v):
                let r = ImageRenderer(content: PopoverView().environmentObject(model)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, v == "light" ? .light : .dark))
                r.scale = 2
                if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("popover-\(v).png"))
                }
            case ("account", let v): UserDefaults.standard.set(v == "all" ? "" : v, forKey: "chats.account")
            default: break
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let policy = NSApp.activationPolicy() == .regular ? "regular" : NSApp.activationPolicy() == .accessory ? "accessory" : "prohibited"
            let state = "policy=\(policy) menubar=\(model.config.showInMenuBar) dock=\(model.config.showInDock) "
                + "delay=\(model.config.retryDelaySeconds) section=\(model.section?.rawValue ?? "-") "
                + "mainVisible=\(model.mainWindow?.isVisible ?? false)\n"
            try? state.write(to: dir.appendingPathComponent("state"), atomically: true, encoding: .utf8)
        }
    }

    static func capture(to dir: URL) {
        for (i, w) in NSApp.windows.enumerated() where w.isVisible && w.frame.width > 200 {
            guard let v = w.contentView?.superview ?? w.contentView,
                  let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            // Materials (the sidebar) don't draw into a cached bitmap; flatten them for the capture.
            var saved: [(NSVisualEffectView, NSVisualEffectView.BlendingMode, NSVisualEffectView.State)] = []
            func walk(_ x: NSView) {
                if let e = x as? NSVisualEffectView { saved.append((e, e.blendingMode, e.state)); e.blendingMode = .withinWindow; e.state = .inactive }
                x.subviews.forEach(walk)
            }
            walk(v)
            v.displayIfNeeded()
            v.cacheDisplay(in: v.bounds, to: rep)
            for (e, b, st) in saved { e.blendingMode = b; e.state = st }
            let name = (w.identifier?.rawValue ?? "window").replacingOccurrences(of: "/", with: "_")
            try? rep.representation(using: .png, properties: [:])?
                .write(to: dir.appendingPathComponent("\(i)-\(name).png"))
        }
    }
}
#endif
