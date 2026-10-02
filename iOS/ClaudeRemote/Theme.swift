import SwiftUI
import UIKit
import WatchProtocol

/// The ClaudeWatch menu-bar look (Sources/ClaudeWatch/App.swift `Theme`), scaled up for touch.
/// Fonts are text-style based so they still follow Dynamic Type (subheadline ≈ 15, footnote ≈ 13, caption2 ≈ 11).
enum Theme {
    // Status colours are the Mac's on the near-black background; on white they are a shade deeper so text
    // in them stays readable (the Mac yellow and green are under 2:1 on white).
    static let clay = adaptive(dark: (0.851, 0.467, 0.341), light: (0.80, 0.40, 0.27))
    static let green = adaptive(dark: (0.47, 0.75, 0.47), light: (0.18, 0.55, 0.25))
    static let yellow = adaptive(dark: (0.86, 0.70, 0.35), light: (0.66, 0.47, 0.04))
    static let red = adaptive(dark: (0.90, 0.40, 0.40), light: (0.80, 0.22, 0.22))

    private static func adaptive(dark: (CGFloat, CGFloat, CGFloat), light: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(uiColor: UIColor { t in
            let c = t.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    static let mono = Font.system(.subheadline, design: .monospaced)
    static let monoSmall = Font.system(.footnote, design: .monospaced)
    static let monoTiny = Font.system(.caption2, design: .monospaced)
    static let monoBold = Font.system(.subheadline, design: .monospaced, weight: .semibold)
    static let monoTitle = Font.system(.body, design: .monospaced, weight: .semibold)

    static let uiClay = UIColor(red: 0.851, green: 0.467, blue: 0.341, alpha: 1)
    /// Near-black in dark mode (like the menu-bar popover), the plain system background in light mode.
    static let background = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.07, alpha: 1) : .systemBackground })
    static let highlight = Color.primary.opacity(0.06)
    static let code = Color.primary.opacity(0.06)
    static let hairline = Color.primary.opacity(0.12)

    static func color(_ s: AccountState) -> Color {
        switch s {
        case .free: green
        case .working: clay
        case .limited: red
        case .offline: .secondary
        }
    }

    static func label(_ s: AccountState) -> String {
        switch s {
        case .free: "free"
        case .working: "working"
        case .limited: "limited"
        case .offline: "not running"
        }
    }

    static func color(_ c: RemoteStore.Connection) -> Color {
        switch c {
        case .connected: green
        case .connecting, .reconnecting: yellow
        case .offline: red
        }
    }

    static func label(_ c: RemoteStore.Connection) -> String {
        switch c {
        case .connected: "live"
        case .connecting: "connecting"
        case .reconnecting: "reconnecting"
        case .offline: "mac unreachable"
        }
    }

    /// UIKit chrome (tab bar, nav bar, segmented controls) in the same monospaced type.
    @MainActor static func applyAppearance() {
        func mono(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
            UIFontMetrics.default.scaledFont(for: .monospacedSystemFont(ofSize: size, weight: weight))
        }
        UITabBarItem.appearance().setTitleTextAttributes([.font: mono(10, .medium)], for: .normal)
        let nav = UINavigationBar.appearance()
        nav.titleTextAttributes = [.font: mono(16, .semibold)]
        nav.largeTitleTextAttributes = [.font: mono(28, .bold)]
        UIBarButtonItem.appearance().setTitleTextAttributes([.font: mono(15)], for: .normal)
        UISegmentedControl.appearance().setTitleTextAttributes([.font: mono(12, .medium)], for: .normal)
        UISegmentedControl.appearance().selectedSegmentTintColor = uiClay.withAlphaComponent(0.85)
        UISegmentedControl.appearance().setTitleTextAttributes([.font: mono(12, .semibold), .foregroundColor: UIColor.white],
                                                               for: .selected)
        UISearchTextField.appearance().font = mono(15)
    }
}

// MARK: - Small building blocks

/// Tinted state badge: "free", "limited · 3:40pm".
struct Badge: View {
    let text: String
    let color: Color
    var font: Font = Theme.monoSmall

    var body: some View {
        Text(text)
            .font(font)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.15)))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }
}

/// Thin usage bar: clay, yellow from 70 %, red from 90 %.
struct UsageBar: View {
    let percent: Double?

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.08))
                if let p = percent {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(p >= 90 ? Theme.red : p >= 70 ? Theme.yellow : Theme.clay)
                        .frame(width: g.size.width * min(1, max(0, p / 100)))
                }
            }
        }
        .frame(height: 5)
        .animation(.snappy, value: percent)
        .accessibilityHidden(true)
    }
}

/// "5h ▬▬▬▬░░ 64%  ~48m to cap"
struct LimitRow: View {
    let label: String
    let f: LimitForecast
    let pace: Double
    let now: Date
    @ScaledMetric(relativeTo: .footnote) private var percentWidth: CGFloat = 42
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary).fixedSize()
            // A fifth of the screen (so the 5h and 7d bars line up), leaving the forecast
            // ("safe · resets Mon 11:24am") room for its words on a narrow phone.
            UsageBar(percent: f.percent)
                .containerRelativeFrame(.horizontal) { w, _ in min(110, max(56, w * 0.2)) }
            Text(Fmt.percent(f.percent))
                .contentTransition(.numericText())
                .fixedSize()
                .frame(minWidth: percentWidth, alignment: .trailing)
            Text(Fmt.forecast(f, pace: pace, now: now))
                .foregroundStyle(soon ? Theme.clay : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(typeSize > .large ? 2 : 1)   // at big text sizes wrap rather than lose the reset time
                .minimumScaleFactor(0.85)
        }
        .animation(.snappy, value: f.percent)
        .font(Theme.monoSmall)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(Fmt.percent(f.percent)), \(Fmt.forecast(f, pace: pace, now: now))")
    }

    private var soon: Bool {
        guard let h = f.hitsAt, !f.resetsFirst, (f.percent ?? 0) < 100 else { return false }
        return h.timeIntervalSince(now) < 3600
    }
}

struct ConnectionDot: View {
    let connection: RemoteStore.Connection
    var body: some View {
        Circle().fill(Theme.color(connection)).frame(width: 8, height: 8)
            .animation(.easeInOut, value: connection)
            .accessibilityLabel(Theme.label(connection))
    }
}

/// A section title: semibold, lowercase, with an optional trailing item.
struct SectionTitle<Trailing: View>: View {
    let title: String
    var count: Int?
    @ViewBuilder var trailing: Trailing

    init(title: String, count: Int? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.count = count
        self.trailing = trailing()
    }

    init(_ title: String, count: Int? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.init(title: title, count: count, trailing: trailing)
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(Theme.monoBold)
            if let count {
                Text("\(count)").font(Theme.monoSmall).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: count)
            }
            Spacer()
            trailing
        }
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

extension SectionTitle where Trailing == EmptyView {
    init(_ title: String, count: Int? = nil) {
        self.title = title
        self.count = count
        self.trailing = EmptyView()
    }
}

/// "✓ paired" / "✗ push isn't set up"
struct StatusLine: View {
    let ok: Bool
    let text: String
    var warn = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(ok ? "✓" : "✗").foregroundStyle(ok ? Theme.green : warn ? Theme.yellow : Theme.red).fixedSize()
            Text(text)
            Spacer(minLength: 0)
        }
        .font(Theme.monoSmall)
    }
}

/// A bordered monospaced input box.
struct FieldBox: ViewModifier {
    var focused = false
    func body(content: Content) -> some View {
        content
            .font(Theme.mono)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.code))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? Theme.clay : Theme.hairline))
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

extension View {
    func fieldBox(focused: Bool = false) -> some View { modifier(FieldBox(focused: focused)) }

    /// Plain near-black / white screen background.
    func screenBackground() -> some View {
        background(Theme.background.ignoresSafeArea())
    }
}

// MARK: - Button styles

/// Filled clay: the primary action ("allow", "pair", "start"). At least 44pt tall, like every tap target.
struct ClayButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var fill = Theme.clay
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.monoBold)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 6).fill(fill.opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.35)))
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

/// Thin outline ("always", "stop").
struct OutlineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var color: Color = .primary
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.mono)
            .foregroundStyle(color.opacity(enabled ? 1 : 0.35))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 6).fill(configuration.isPressed ? Theme.highlight : .clear))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(color.opacity(enabled ? 0.35 : 0.15)))
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

/// Link-style text button (clay by default, red for destructive). It stays compact in the layout, but its
/// tap area reaches out to 44pt so it is easy to hit inside dense rows.
struct LinkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var color: Color = Theme.clay
    var font: Font = Theme.monoSmall
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .foregroundStyle(color.opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.35))
            .padding(.vertical, 4)
            .contentShape(Rectangle().inset(by: -8))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Full-width row that highlights while pressed (for navigation rows).
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 5).fill(configuration.isPressed ? Theme.highlight : .clear))
            .animation(.easeOut(duration: configuration.isPressed ? 0.05 : 0.25), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == ClayButtonStyle { static var clay: ClayButtonStyle { ClayButtonStyle() } }
extension ButtonStyle where Self == OutlineButtonStyle { static var outline: OutlineButtonStyle { OutlineButtonStyle() } }
extension ButtonStyle where Self == LinkButtonStyle { static var clayLink: LinkButtonStyle { LinkButtonStyle() } }
extension ButtonStyle where Self == RowButtonStyle { static var row: RowButtonStyle { RowButtonStyle() } }

// MARK: - Motion and haptics

/// Claude's working glyph, cycling "· ✢ ✳ ✶ ✻ ✽" like the CLI spinner; a still ✻ with Reduce Motion.
struct BusyGlyph: View {
    var color: Color = Theme.clay
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let frames = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.12)) { ctx in
            let i = Int(ctx.date.timeIntervalSinceReferenceDate / 0.12) % Self.frames.count
            Text(reduceMotion ? "✻" : Self.frames[i])
                .foregroundStyle(color)
        }
        .fixedSize()
        .accessibilityHidden(true)
    }
}

/// "✻ loading transcript…": the terminal-style loading line.
struct LoadingLine: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            BusyGlyph()
            Text(text).foregroundStyle(.secondary)
        }
        .font(Theme.monoSmall)
        .accessibilityElement(children: .combine)
    }
}

@MainActor enum Haptics {
    static func send() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func allow() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func deny() { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
}
