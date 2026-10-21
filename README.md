<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# End-to-end encrypted chat (source release)

Source for the chat and end-to-end-encryption layer of an iOS/macOS app and its
Rust backend: Signal Protocol (libsignal, PQXDH + Double Ratchet) for messages,
groups, multiple devices, attachments, view-once media, live location, call
signalling, push-notification decryption and safety numbers.

License: **AGPL-3.0-only** (libsignal is AGPL-3.0-only). See `LICENSE` and `NOTICE`.

## Layout
| Path | Contents |
|---|---|
| `ios/Sources/E2EE/` | New E2EE modules (engine, store, service, attachment crypto, media, safety numbers, views, NSE decryptor) |
| `ios/Sources/Chat/` | Chat files modified to call the E2EE layer |
| `backend/src/` | `models_e2ee.rs`, `e2ee_service.rs`, patched `chat.rs`, `media.rs`, `protocol.rs`, `session.rs`, ... |
| `backend/migrations/` | `0XX_e2ee_signal.sql` (rename to your next migration number) |
| `docs/` | Integration guides and protocol summary |

## Setup
* Client (entitlements, App Group, Keychain access group, NSE): `docs/IOS_INTEGRATION.md`
* Server (env flags, routes): `docs/BACKEND_INTEGRATION.md`
* Wire/crypto summary: `docs/PROTOCOL.md`

Security reports: `SECURITY.md`.
