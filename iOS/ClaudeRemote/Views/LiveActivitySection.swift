import SwiftUI

/// "lock screen" switch under the accounts: keeps every account's limits on the Lock Screen, in the Dynamic Island
/// and, with the iPhone nearby, in the Mac's menu bar.
struct LiveActivitySection: View {
    @Environment(RemoteStore.self) private var store

    var body: some View {
        @Bindable var live = store.live
        Divider()
        SectionTitle("lock screen")
        Toggle(isOn: $live.enabled) {
            HStack(spacing: 6) {
                Text("▸").foregroundStyle(Theme.clay).fixedSize()
                Text("limits live activity")
                Spacer(minLength: 4)
                if live.enabled && live.allowed {
                    Text(live.running ? "on" : "starting…").foregroundStyle(live.running ? Theme.green : .secondary)
                }
            }
        }
        .frame(minHeight: 40)
        .font(Theme.monoSmall)
        .tint(Theme.clay)
        .disabled(!store.isPaired)
        Text(live.allowed
             ? "5h and 7d use for every account on the Lock Screen and in the Dynamic Island; on macOS 26 it shows in the Mac's menu bar too. Add the \"Claude limits\" widget for the Home Screen or the Mac desktop."
             : "Live Activities are off for Session Watch in Settings.")
            .font(Theme.monoTiny)
            .foregroundStyle(live.allowed ? Color.secondary : Theme.red)
            .padding(.leading, 14)
            .padding(.bottom, 10)
    }
}
