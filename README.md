<p align="center">
  <img src="docs/brand/volley-mark.svg" width="96" height="96" alt="Volley logo: an arc served from one dot to another">
</p>

<h1 align="center">volley</h1>

<p align="center"><b>Your Android phone's texts and notifications, on your Mac.</b></p>

<p align="center">
  <a href="https://github.com/JacobAtchley/volley/actions/workflows/ci.yml"><img src="https://github.com/JacobAtchley/volley/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-FF9E8F?labelColor=2A1F1D" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Android-8%2B-FF9E8F?labelColor=2A1F1D" alt="Android 8+">
</p>

<p align="center">💬 Read &amp; reply to SMS · 🔔 Notification history · 🔋 Phone status</p>

<p align="center">A menu bar app pairs with your phone over your Wi‑Fi. No cloud, no account.</p>

## Project layout

```
android/   Kotlin app: reads notifications + SMS, sends replies (Android 8.0+)
mac/       Swift menu bar app: Bonjour WebSocket server, native notifications (macOS 14+)
docs/      PROTOCOL.md: the JSON wire protocol shared by both; brand/: the logo
```

## How it works

1. The Mac app advertises `_volley._tcp` on your network and listens for a WebSocket.
2. The phone finds it, pairs once with a 6-digit code, and gets a token (the Mac keeps only a hash of it).
3. After that the phone reconnects on its own and streams `notification.posted` / `sms.received`.
   Replies and "Dismiss on phone" go back as `sms.send` / `notification.dismiss`.

Phone and Mac each talk to the network through an interface (`Transport` / `PhoneTransport`).
To add a cloud relay later, write a second implementation and change one line in each app's
composition root (`AppGraph` on Android, `Composition` on the Mac).

## Run it

**Mac**
```sh
brew install xcodegen
cd mac && xcodegen && open Volley.xcodeproj
```
Run it, then click the arc icon in the menu bar and choose **Pair a phone**. Allow notifications and local network access when macOS asks.
Choose **Open Volley** for the messages window: your phone's battery, charging, cell and Wi-Fi status,
today's text conversations, and a chat view to reply. Messages are kept on the Mac in
`~/Library/Application Support/Volley/volley.sqlite`.
The **Notifications** area keeps every notification the phone mirrors, marks what's new since you last
looked, and has fuzzy search. Use **Mirrored Apps…** (or right-click → Don't Mirror) to stop mirroring apps
that already notify you on the Mac, like Slack. The menu bar shows how many are new.
The **Files** area shows the phone's storage next to a Mac folder: drag between the two panes (or to Finder)
to copy, double-click to open in the Mac's default app, right-click to delete on the phone. List or Icons
view and the sort order are remembered per folder; camera folders open newest first.

**Android**
Open `android/` in Android Studio and run on a device on the same Wi-Fi, or run `./gradlew installDebug`.
In the app: grant **Text messages**, **Contacts**, **Notification access** and (for Files) **All files access**,
pick your Mac and enter the code.
**Send test notification** posts one on demand so you can check mirroring end to end.

On Android 13+, a sideloaded app needs one extra step before you can grant Notification access:
go to App info → ⋮ → **Allow restricted settings**.

## Known limits (v1)

- **Traffic is unencrypted `ws://` on your LAN.** The next step is TLS with a self-signed Mac
  certificate, pinned on the phone during pairing.
- The phone's token is in plain SharedPreferences; it should move to the Android Keystore.
- Google Play only allows SMS permissions for default SMS apps, so for now the Android app has to be sideloaded.
- Android only exposes notifications that are still showing, so one posted and cleared while the Mac was
  disconnected can't be recovered.
- Only text SMS are mirrored; MMS (pictures, group chats) isn't yet. History starts from today when first synced.
- Only one phone is connected at a time.
- Files can't reach other apps' private storage (`Android/data`, `Android/obb`); only shared storage.
  Transfers don't resume after a disconnect, and folders copy to Finder via **Download to…** rather than drag.
- The Mac app isn't sandboxed (the Files pane browses any folder you open).
