import SwiftUI
import WatchProtocol

/// The app's terminal look, for the extension (which can't see the app's Theme).
enum WTheme {
    static let clay = Color(red: 0.851, green: 0.467, blue: 0.341)
    static let green = Color(red: 0.47, green: 0.75, blue: 0.47)
    static let yellow = Color(red: 0.86, green: 0.70, blue: 0.35)
    static let red = Color(red: 0.90, green: 0.40, blue: 0.40)
    static let graphite = Color(red: 0.086, green: 0.094, blue: 0.114)
    static let dim = Color.white.opacity(0.55)
    static let track = Color.white.opacity(0.14)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func color(_ s: AccountState) -> Color {
        switch s {
        case .free: green
        case .working: yellow
        case .limited: red
        case .offline: Color.gray
        }
    }

    static func label(_ s: AccountState) -> String {
        switch s {
        case .free: "free"
        case .working: "working"
        case .limited: "limited"
        case .offline: "offline"
        }
    }

    /// Green under 70%, yellow under 90%, red from there.
    static func level(_ p: Int?) -> Color {
        guard let p else { return .gray }
        return p >= 90 ? red : p >= 70 ? yellow : green
    }

    static func percent(_ p: Int?) -> String { p.map { "\($0)%" } ?? "—" }
}

/// A thin block-style meter: the app's usage bar.
struct Meter: View {
    let percent: Int?
    var height: CGFloat = 5
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(WTheme.track)
                Capsule().fill(WTheme.level(percent))
                    .frame(width: max(percent == nil || percent == 0 ? 0 : height, g.size.width * CGFloat(min(100, percent ?? 0)) / 100))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// "1:42:10" counting down to `date`, or nothing once it has passed.
struct Countdown: View {
    let date: Date?
    var prefix = ""
    var body: some View {
        if let date, date > Date() {
            HStack(spacing: 0) {
                if !prefix.isEmpty { Text(prefix) }
                Text(timerInterval: Date()...date, countsDown: true, showsHours: true)
                    .monospacedDigit()
            }
        }
    }
}
