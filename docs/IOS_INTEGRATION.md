<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# iOS / macOS integration

Not compiled. Expect a few small API-drift fixes against your pinned LibSignalClient.

## 1. Package
Add `https://github.com/signalapp/libsignal` (product **LibSignalClient**) to both the iOS and Mac targets.
Pin a recent release that has PQXDH (Kyber) APIs. If `E2EEStore.swift` / `E2EEEngine.swift` don't compile,
compare against that release's `InMemorySignalProtocolStore.swift`; the usual drift is `saveIdentity`
(return type `IdentityChange` vs `Bool`) and `markKyberPreKeyUsed` (parameter list).

## 2. Files
New (both targets): `E2EE/E2EEModels.swift`, `E2EEStore.swift`, `E2EEEngine.swift`, `E2EENetworkService.swift`,
`E2EEService.swift`, `E2EEViews.swift`, `E2EEAttachmentCrypto.swift`, `E2EEMedia.swift`, `E2EESafetyNumber.swift`.
New (Notification Service Extension only): `E2EE/E2EENotificationDecryptor.swift`.

Patched copies replace the originals (see `patches/*.diff`): ChatModels, ChatNetworkService, NetworkService,
ChatWebSocketClient, AuthService, ConversationViewModel, ConversationView, ParticipantsView, ParticipantsViewModel,
ChatListViewModel, ChatMediaUploader, ChatLocalStore, LiveLocationShareManager, CallManager, NotificationService,
CachedThumbnailImage, MediaGalleryViewController, VoiceMessagePlayer, BitPlayerView, BitPrefetchCache.

`E2EEAttachmentCrypto` and `E2EEMedia` are needed only in the main app, not the extension.

## 3. UI
The patched `ParticipantsView` shows a read-only encryption status row (group and 1:1) and a "Verify safety number"
entry. Optional: `E2EELockBadge` next to the conversation title, and `E2EELinkedDevicesView` in Settings.

## 4. Push notifications (Notification Service Extension)
A push for an encrypted message arrives as "New message". The extension fetches this device's ciphertext
(`GET .../messages/{id}/e2ee-push`, authenticated with the same token as the delivered-ack), decrypts it, and
replaces the body. In Xcode:
1. NSE target: add the **GRDB** and **LibSignalClient** packages and these files: `E2EEModels.swift`,
   `E2EEStore.swift`, `E2EEEngine.swift`, `E2EENotificationDecryptor.swift`.
2. Put the app, the Mac app and the NSE in the same **App Group** and **Keychain Sharing** group. The device identity
   lives in the shared Keychain group and the database in the App Group container. Set `E2EEShared.appGroupId` and
   `E2EEShared.keychainAccessGroup` to your identifiers (e.g. `group.com.example.app`). Without them everything still
   works, but pushes stay "New message" (the store falls back to private storage).
3. The app and the extension take a cross-process lock (`flock` in the container) around every ratchet step, so a
   push and the foreground app never advance the same session at once. The extension stores the plaintext in the
   shared database, so the app reads it instead of decrypting a second time.
4. Watch for NSE memory limits (~24 MB; libsignal is the largest part, so test on a real low-memory device) and
   `0xdead10cc` crashes (iOS kills a suspended app holding a lock in a shared container). Locks are held for
   milliseconds, so this should not occur; if it does, enable GRDB's `observesSuspensionNotifications`.
5. Foreground/background-socket local notifications show the decrypted text. Tap routing needs no change: the push
   payload keys are unchanged.

## 5. Chat list
Rows for encrypted chats take their preview from the local plaintext cache (socket, extension, or an opened chat).
If the latest message arrived while the app was closed and the push wasn't decrypted, `ChatListViewModel` fetches and
decrypts the latest messages for up to 8 such rows after each list load.

## 6. Design decisions
* Decryption happens at the ingestion boundary (REST page, websocket `new_message` / `message_ack` /
  `message_edited`), so the local store, view models and notifications only ever see ordinary text.
* A Signal ciphertext can be decrypted once, so plaintext is cached in a per-account E2EE SQLite database
  (`e2ee_plaintext`, keyed by clientMsgId + rev). It is excluded from backup, file-protected, and wiped on sign-out.
* Each install is its own device (own device id, identity key, prekeys). The Mac app is just another device. Senders
  encrypt to every device of every member, including the sender's other devices.
* History: a new device, or a member who joined later, can't read earlier messages and sees an "Encrypted message,
  not available on this device" placeholder.
* Sign-out = unlink: revokes the device on the server and wipes local E2EE state (`E2EEService.wipeOnSignOut`).
  Set it to `false` to keep state on disk per account.
* Encryption is on by default. Every send is encrypted per device (`E2EEService.sendEncryptedIfPossible`) and the
  server enables encryption for the chat on the first one. If a member of a not-yet-encrypted chat has no encrypted
  device, or this device isn't registered yet, the message goes as plaintext (never blocks sending). Once a chat is
  encrypted, content is never sent in the clear; the send fails instead.
* Socket sends carry the ciphertexts. A rejected socket send arrives as `send_failed`: `e2ee/devices-changed` ->
  re-encrypt and resend; anything else -> REST fallback. Timeouts also fall back to REST with the same
  `client_msg_id`, so nothing is stored twice.
* `E2EEService.bootstrap` is detached and non-throwing, and nothing runs in an `init`, so an engine failure results
  in placeholders and the app keeps working.

## 7. Attachments, bits, voice, files
`ChatMediaUploader.uploadForConversation(id) { ...upload... }` encrypts every file it uploads (AES-256-GCM, 256 KiB
chunks, random key per file) and stores the blob under `chat/e2ee/` as `.bin`. URL, key, SHA-256, size, mime, name,
dimensions, duration and thumbnail reference go inside the Signal ciphertext; the server sees only `content_type`
(plus `view_duration_seconds` / `is_live_location`).

The sender keeps a plaintext copy in `Application Support/e2ee-media/` (name = hash of the blob URL). Recipients
download, verify the digest, and decrypt to the same folder; the message then gets `file://` `mediaUrl` /
`thumbnailUrl`. REST pages hydrate concurrently; websocket `new_message` / `message_ack` are delivered after the media
is ready, so a large video delays its bubble until downloaded. `E2EEMedia.rebase` fixes stale container paths. Chat
list previews and notifications read "Photo", "Video", "Voice message", "Bit", file name, or "Location".
Media never falls back to plaintext once chosen; `shouldEncrypt` decides before uploading.

Viewer/player changes: `CachedThumbnailImage` (file URLs via `LocalFileImageDataProvider`),
`MediaGalleryViewController` (file URLs for image/video/QuickLook, skips `MediaFileCache`), `VoiceMessagePlayer`,
`BitPlayerView`, `BitPrefetchCache`. Documents are stored as `<hash>/<original name>` so file bubbles still show the
real name.

**View-once bits stay memory-only.** A bit from someone else is never decrypted to disk: its `mediaUrl` is a pseudo
URL `e2eebit://<messageId>.<ext>`, and `BitPrefetchCache.prefetch` (or the player as a fallback) downloads the blob and
decrypts it in memory (`E2EEBitLoader`). `BitPrefetchCache.discard` (on open or expiry) also deletes the key from the
local cache so the blob can't be decrypted again. Bit thumbnails are decrypted to disk. Your own bits keep a local
plaintext copy so you can re-preview them.

## 8. Location and calls
* **Location.** One-shot and "started sharing" messages carry lat/lng inside the ciphertext. Live pings go as
  `location_update_e2ee` frames (per-device ciphertexts); the server refuses plaintext pings in encrypted chats.
* **Calls.** In an encrypted chat every `call_signal` except `end` is wrapped (`payload = {type, e2ee:{...}}`): SDP
  (including the DTLS fingerprint) and ICE candidates (IP addresses) are per-device Signal ciphertexts. Media is
  DTLS-SRTP; this additionally stops the server from swapping fingerprints. A replayed signal fails to decrypt a
  second time and is dropped.

## 9. Safety numbers
`ParticipantsView` (direct and group) shows "Verify safety number" when a chat is encrypted. It opens
`E2EESafetyNumberView` (in `E2EEViews.swift`): a list of the other members, each opening a 60-digit number, a QR code,
Copy / Share, and "Mark as verified". Both people see the same number (`E2EESafetyNumber.swift`: 5200 rounds of
SHA-512 over each person's device identity keys + user id, two 30-digit halves ordered). Because every install is its
own device, a new device, reinstall or swapped key changes the number. A verified number that later differs shows an
orange "has changed" banner, and a server-reported key that differs from the one this phone pinned shows a red
warning. Keys come from this phone's pinned identities (what messages actually use), falling back to the server's
list for devices without a session yet. Verified state lives in the E2EE database (migration `e2ee_v3_verified`).

## 10. Known limits
* Not compiled or run. `LocalFileImageDataProvider` and the pseudo-URL path need a device test.
* No key backup and no multi-device history sync.
* A push the extension can't decrypt (not signed in, no network in time, no keys) still reads "New message".
* `ChatLocalStore` persists decrypted text, coordinates and local media paths unencrypted at rest.
* Bits: the sender and recipient keep a decrypted copy on disk after viewing; delete it on expiry if that matters.
  The server stops serving ciphertexts of expired bits, but the encrypted blob stays in object storage until a
  lifecycle rule on `chat/e2ee/` removes it.
* The QR code in safety numbers is for another phone's camera; there is no in-app scanner.
