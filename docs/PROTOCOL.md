# Volley wire protocol (v1)

Transport: WebSocket text frames, one JSON envelope per frame.
LAN discovery: the Mac advertises Bonjour/mDNS service `_volley._tcp` with TXT `id=<macId>`, `v=1`.
The Mac is the server; the phone is the client.

## Envelope

```json
{ "type": "sms.received", "id": "uuid", "ts": 1729600000000, "body": { } }
```

## Session

1. Phone connects.
2. First frame MUST be `hello` (paired) or `pair.request` (unpaired). Anything else closes the socket.
3. Mac answers `hello.ok` / `pair.result`; on failure it sends the result then closes.

## Messages

| type                   | dir          | body |
|------------------------|--------------|------|
| `pair.request`         | phone → mac  | `deviceId`, `deviceName`, `code` (6 digits shown on the Mac) |
| `pair.result`          | mac → phone  | `ok`, `macId`, `macName`, `token?` |
| `hello`                | phone → mac  | `deviceId`, `deviceName`, `token` |
| `hello.ok`             | mac → phone  | `macId`, `macName` |
| `notification.posted`  | phone → mac  | `key`, `pkg`, `appName`, `title`, `text`, `postedAt` |
| `notification.removed` | phone → mac  | `key` |
| `notification.dismiss` | mac → phone  | `key` |
| `sms.received`         | phone → mac  | `address`, `body`, `receivedAt` |
| `sms.send`             | mac → phone  | `requestId`, `address`, `body`, `threadId?` |
| `sms.sent`             | phone → mac  | `requestId`, `ok`, `error?` |
| `sms.sync`             | mac → phone  | `sinceId` (phone SMS `_id`, 0 if none), `sinceTime` (epoch ms), `pendingIds` (ids the Mac holds as pending) |
| `sms.batch`            | phone → mac  | `messages` (`[SmsRecord]`), `done` |
| `device.status`        | phone → mac  | `battery` (0–100), `charging`, `cellLevel?` (0–4), `wifiLevel?` (0–4), `wifiConnected` |

`SmsRecord`: `id` (phone SMS `_id`), `threadId`, `address`, `contactName?`, `body`, `date` (epoch ms),
`outgoing`, `status` (`received` | `sent` | `pending` | `failed`). Text SMS only; MMS is not synced.

## SMS history sync

1. After `hello.ok` / `pair.result`, the Mac sends `sms.sync` with the highest `_id` it has stored for this
   phone and `sinceTime` = local midnight today. The phone never sends rows older than `sinceTime`.
2. The phone replies with `sms.batch` frames of up to 200 records; the last has `done: true`
   (an empty result is one empty `done` batch).
3. While connected, the phone observes its SMS provider and sends further `sms.batch` frames (`done: true`)
   with new rows, plus rows previously sent as `pending` whose status has since changed.
4. The Mac upserts records by (phone, `id`), so resending a row updates it.

When the phone sends an `sms.send`, Android records it in the provider's sent box (verified on a Galaxy S24 Ultra,
Android 14+: `creator=app.volley.android`), so the Mac's copy comes back through step 3 and replaces its optimistic one.

`sms.received` is still sent for incoming SMS; the Mac uses it only for desktop notifications.

The phone sends `device.status` once after authenticating and then when a value changes,
at most every 30 s (a charging change is sent immediately).

Liveness uses WebSocket ping/pong frames, not envelopes.

## Security (v1 limitations)

- The token is 32 random bytes (base64url), issued once at pairing; the Mac keeps it in the Keychain.
- **v1 is plaintext `ws://` on the LAN.** Next step: TLS with a self-signed Mac certificate
  whose SHA-256 fingerprint is exchanged during pairing and pinned on the phone.
