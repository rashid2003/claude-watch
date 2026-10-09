# Buddy: a character that shows if agents work or need you

A small animated friend. Moods (most urgent first): needs you (waves, "!" bubble with the chat name), error
(shakes, sweat drop), celebrating (confetti when a chat finishes), busy (walks along the bottom), sleeping.

- Mood logic: `Sources/WatchCore/BuddyState.swift` (`BuddyTracker`, tested in `BuddyStateTests`).
- Characters (Blobby, Pixel, Bolt) drawn in SwiftUI Canvas from one `BuddyPose`: `Sources/ClaudeWatch/Buddy/BuddyArt.swift`.
- Places, each a setting (UserDefaults, not config.json): screen pet (floating panel above the Dock, draggable,
  walks while busy), Dock tile (needs "Show in Dock"), menu bar item (chat list by state).
- Click opens the exact chat: desktop chats via `WatchModel.open`; terminal chats find the live `claude` pid in
  the profile's `sessions/` registry, then select its tab in iTerm2 / Terminal / tmux or raise the owning app.
- Settings > Buddy has a "Preview a mood" picker. Debug builds: `SW_BUDDY_MOOD`, `SW_BUDDY_STYLE`.
- Touches existing files only at two spots: `App.swift` (start) and `SettingsView.swift` (one section).
