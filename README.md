# Volley

Mirror your Android phone's SMS and notifications to your Mac.

```
android/   Kotlin app: reads notifications + SMS, sends replies (Android 8.0+)
mac/       Swift menu bar app: Bonjour WebSocket server, native notifications (macOS 14+)
docs/      PROTOCOL.md: the JSON wire protocol shared by both
```

## How it works

1. The Mac app advertises `_volley._tcp` on your network and listens for a WebSocket.
2. The phone finds it, pairs once with a 6-digit code, and gets a token (stored in the Mac's Keychain).
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

**Android**
Open `android/` in Android Studio and run on a device on the same Wi-Fi, or run `./gradlew installDebug`.
In the app: grant **Text messages** and **Notification access**, pick your Mac and enter the code.

On Android 13+, a sideloaded app needs one extra step before you can grant Notification access:
go to App info → ⋮ → **Allow restricted settings**.

## Known limits (v1)

- **Traffic is unencrypted `ws://` on your LAN.** The next step is TLS with a self-signed Mac
  certificate, pinned on the phone during pairing.
- The phone's token is in plain SharedPreferences; it should move to the Android Keystore.
- Google Play only allows SMS permissions for default SMS apps, so for now the Android app has to be sideloaded.
- Contact names aren't resolved yet (you'll see phone numbers).
- Only one phone is connected at a time.
