import SwiftUI
import WatchCore

/// The "buddy" section of Settings: where it lives, which character, and a way to see every mood.
struct BuddySettingsSection: View {
    @ObservedObject private var prefs = BuddyPrefs.shared
    @ObservedObject private var ctl = BuddyController.shared
    @ObservedObject private var brain = BuddyController.shared.brain

    var body: some View {
        Section {
            Toggle("On the screen", isOn: $prefs.showPet)
            Toggle("In the Dock icon", isOn: $prefs.showDock)
            Toggle("In the menu bar", isOn: $prefs.showMenuBar)
            Toggle("Walks around while chats work", isOn: $prefs.walks).disabled(!prefs.showPet)
            Toggle("Speech bubble with the chat name", isOn: $prefs.showBubble).disabled(!prefs.showPet)
            Toggle("Celebrates when a chat finishes", isOn: $prefs.celebrates)
            LabeledContent("Size") {
                Slider(value: $prefs.scale, in: 0.7...1.6).frame(width: 170)
            }.disabled(!prefs.showPet)
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
            LabeledContent("Preview an activity") {
                Picker("", selection: $prefs.previewActivity) {
                    Text("Follow its life").tag(BuddyActivity?.none)
                    ForEach(BuddyActivity.allCases) { Text($0.title).tag(BuddyActivity?.some($0)) }
                }.labelsHidden().frame(width: 170)
            }
        } header: { Text("BUDDY") } footer: {
            Text("A little friend that shows if your chats are working or need you. Click it to open the chat that needs you. The Dock icon needs “Show in Dock”.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// "Life & mind": what the buddy does on its own, and what it learns. Everything lives in JSON files.
struct BuddyMindSettingsSection: View {
    @ObservedObject private var prefs = BuddyPrefs.shared
    @ObservedObject private var brain = BuddyController.shared.brain

    var body: some View {
        Section {
            Toggle("Has its own life (eats, sleeps, watches movies…)", isOn: $prefs.lifeEnabled)
            Toggle("Learns by itself and tells me", isOn: Binding(get: { brain.mindConfig.enabled }, set: { brain.setMindEnabled($0) }))
                .disabled(!prefs.lifeEnabled)
            LabeledContent("Notebook") {
                Button("Open (\(brain.memory.learned.count) things, \(brain.unread.count) new)") { BuddyController.shared.showNotebook() }
            }
            LabeledContent("\(brain.name)'s files") {
                HStack {
                    Button("Edit life.json") { brain.edit(brain.files.life) }
                    Button("Edit mind.json") { brain.edit(brain.files.mind) }
                    Button("Show folder") { brain.reveal() }
                }
            }
            ForEach(brain.fileErrors, id: \.self) { e in
                Label(e + ". Using the defaults until you fix it.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
            }
            if let e = brain.lastRunError { Text(e).font(.caption).foregroundStyle(.orange) }
        } header: { Text("LIFE & MIND") } footer: {
            Text("Each character has its own life.json (what it does and when), mind.json (what it is curious about, what it follows such as movie news, its limits) and memory.json. Edit them any time; changes apply within seconds. Its mind can only search and read the web, uses your Claude login, and stays within the limits in mind.json (default: up to \(brain.mindConfig.limits.maxLearnsPerDay) searches a day with a small, cheap model).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
