# App Store Connect: listing and submission notes

## Before the first upload (one time)
1. Sign in to Xcode › Settings › Accounts with the Apple ID for team **6W5NJUTUCV**, or
   create an App Store Connect API key (Users and Access › Integrations › App Store Connect API,
   "App Manager" role) and pass it to `scripts/release.sh` through `ASC_KEY_PATH`, `ASC_KEY_ID`
   and `ASC_ISSUER_ID`.
2. App Store Connect › Apps › **+ New App**: iOS, bundle ID `dev.lajward.ClaudeRemote`
   (Xcode registers it on the first archive with `-allowProvisioningUpdates`), SKU `claude-remote`.
3. Run `iOS/scripts/release.sh`. The build appears under TestFlight after processing.

## TestFlight (recommended)
- **Internal testing** (your own team, up to 100 people) needs **no review**: add yourself as an
  internal tester and install from the TestFlight app.
- External testing needs Beta App Review; use the review notes below.

## Public App Store: read first
- **Name.** "Claude" is Anthropic's trademark. App Review usually rejects names that use another
  company's mark (guideline 5.2.1) without permission. A neutral name avoids this, e.g. **"Watch
  Remote: AI Sessions"** or **"Lajward Remote"**. The display name lives in `Info.plist`
  (`CFBundleDisplayName`).
- **It needs software reviewers don't have** (ClaudeWatch on a Mac, plus Tailscale), so the review
  notes must point them to demo mode (guideline 2.1).

## Listing (draft)
**Subtitle:** Your Mac's AI coding sessions, in your pocket

**Description:**
Keep an eye on the AI coding sessions running on your Mac, and keep them moving, from anywhere.

• Every account at a glance: status, 5-hour and weekly usage, and when you'll hit the cap
• Live chats: read the conversation as it streams, reply, or stop a run
• Prompts that need you: allow or deny tool requests in the app or straight from a notification
• Start new sessions in any project folder
• Retry queue control, retry modes, and moving chats between accounts

Works with ClaudeWatch for macOS over your private Tailscale network. Nothing goes through a
third-party server: the phone talks straight to your Mac, paired by QR code, and every action is
logged on the Mac.

**Keywords:** ai,coding,remote,sessions,mac,usage,limits,developer,terminal,tailscale

**Category:** Developer Tools · **Age rating:** 4+ · **Price:** Free

**Privacy:** "Data Not Collected". The app talks only to the user's own Mac; no analytics and no
tracking. `PrivacyInfo.xcprivacy` declares UserDefaults (CA92.1) only.

**Encryption:** `ITSAppUsesNonExemptEncryption = NO` (standard OS networking and Keychain only).

**Support / privacy policy URL:** needed. A simple page at lajward.dev/remote/privacy saying
"no data collected" is enough.

## Review notes (paste into App Review Information)
This app is the companion to ClaudeWatch, a macOS menu-bar app that runs on the user's own Mac.
Pairing needs that Mac on the same Tailscale network, which reviewers won't have.
To review without a Mac: on the first screen tap **"try demo"**. The app then runs on built-in
sample data, and every screen and action can be explored (actions are simulated).
No account or sign-in is needed.

## Screenshots
6.9" (1320×2868) or 6.7" (1290×2796) iPhone, from demo mode. Take them in the iPhone 16 Pro Max
simulator with `-demo`: Chats, a chat with a prompt card, Accounts, account detail, New chat.
