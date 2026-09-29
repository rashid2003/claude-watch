import SwiftUI
import UIKit
import WatchProtocol

/// The ClaudeWatch menu-bar look (Sources/ClaudeWatch/App.swift `Theme`), scaled up for touch.
/// Fonts are text-style based so they still follow Dynamic Type (subheadline ≈ 15, footnote ≈ 13, caption2 ≈ 11).
enum Theme {
    static let clay = Color(red: 0.851, green: 0.467, blue: 0.341)
    static let green = Color(red: 0.47, green: 0.75, blue: 0.47)
    static let yellow = Color(red: 0.86, green: 0.70, blue: 0.35)
    static let red = Color(red: 0.90, green: 0.40, blue: 0.40)

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

    var body: some View {
        Text(text)
            .font(Theme.monoSmall)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.15)))
            .foregroundStyle(color)
            .lineLimit(1)
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
        .accessibilityHidden(true)
    }
}

/// "5h ▬▬▬▬░░ 64%  ~48m to cap"
struct LimitRow: View {
    let label: String
    let f: LimitForecast
    let pace: Double
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 22, alignment: .leading)
            UsageBar(percent: f.percent).frame(minWidth: 60, maxWidth: 110)
            Text(Fmt.percent(f.percent)).frame(width: 42, alignment: .trailing)
            Text(Fmt.forecast(f, pace: pace, now: now))
                .foregroundStyle(soon ? Theme.clay : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
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
            if let count { Text("\(count)").font(Theme.monoSmall).foregroundStyle(.secondary) }
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
            Text(ok ? "✓" : "✗").foregroundStyle(ok ? Theme.green : warn ? Theme.yellow : Theme.red)
            Text(text).foregroundStyle(ok ? .primary : .primary)
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
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.code))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? Theme.clay : Theme.hairline))
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

/// Filled clay: the primary action ("allow", "pair", "start").
struct ClayButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var fill = Theme.clay
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.monoBold)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 5).fill(fill.opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.35)))
            .contentShape(Rectangle())
    }
}

/// Thin outline ("always", "cancel").
struct OutlineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var color: Color = .primary
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.mono)
            .foregroundStyle(color.opacity(enabled ? 1 : 0.35))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 5).fill(configuration.isPressed ? Theme.highlight : .clear))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(color.opacity(enabled ? 0.35 : 0.15)))
            .contentShape(Rectangle())
    }
}

/// Link-style text button (clay by default, red for destructive).
struct LinkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var color: Color = Theme.clay
    var font: Font = Theme.monoSmall
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .foregroundStyle(color.opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.35))
            .padding(.vertical, 4)
            .contentShape(Rectangle())
    }
}

/// Full-width row that highlights while pressed (for navigation rows).
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 4).fill(configuration.isPressed ? Theme.highlight : .clear))
    }
}

extension ButtonStyle where Self == ClayButtonStyle { static var clay: ClayButtonStyle { ClayButtonStyle() } }
extension ButtonStyle where Self == OutlineButtonStyle { static var outline: OutlineButtonStyle { OutlineButtonStyle() } }
extension ButtonStyle where Self == LinkButtonStyle { static var clayLink: LinkButtonStyle { LinkButtonStyle() } }
extension ButtonStyle where Self == RowButtonStyle { static var row: RowButtonStyle { RowButtonStyle() } }
