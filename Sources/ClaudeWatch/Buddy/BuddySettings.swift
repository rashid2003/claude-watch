import SwiftUI
import WatchCore

/// The "buddy" section of Settings: where it lives, which character, and a way to see every mood.
struct BuddySettingsSection: View {
    @ObservedObject private var prefs = BuddyPrefs.shared

    var body: some View {
        Section {
            Toggle("On the screen", isOn: $prefs.showPet)
            Toggle("In the Dock icon", isOn: $prefs.showDock)
            Toggle("In the menu bar", isOn: $prefs.showMenuBar)
            HStack(spacing: 10) {
                ForEach(BuddyStyle.allCases) { s in
                    Button { prefs.style = s } label: {
                        VStack(spacing: 2) {
                            TimelineView(.animation) { tl in
                                BuddyView(style: s, mood: prefs.preview ?? .busy, t: tl.date.timeIntervalSinceReferenceDate)
                                    .frame(width: 64, height: 64)
                            }
                            Text(s.title).font(.caption)
                        }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 10)
                            .fill(prefs.style == s ? Color.accentColor.opacity(0.2) : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(prefs.style == s ? Color.accentColor : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            LabeledContent("Preview a mood") {
                Picker("", selection: $prefs.preview) {
                    Text("Follow my chats").tag(BuddyMood?.none)
                    ForEach(BuddyMood.allCases, id: \.self) { Text($0.title).tag(BuddyMood?.some($0)) }
                }.labelsHidden().frame(width: 170)
            }
        } header: { Text("BUDDY") } footer: {
            Text("A little friend that shows if your chats are working or need you. Click it to open the chat that needs you. The Dock icon needs “Show in Dock”.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
