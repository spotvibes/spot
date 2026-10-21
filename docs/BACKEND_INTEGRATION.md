<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# Backend integration (Rust)

Not compiled. Run `cargo check` and expect to fix small things.

## Files
| File | Destination |
|---|---|
| `models_e2ee.rs` | `models/e2ee.rs` + `pub mod e2ee;` in `models/mod.rs` |
| `e2ee_service.rs` | `services/e2ee.rs` (core crate) + `pub mod e2ee;` in `services/mod.rs` |
| `patched/chat.rs` | replaces `services/chat.rs` (diff: `patched/chat.rs.diff`) |
| `patched/chat_model.rs` | replaces `models/chat.rs` |
| `patched/chat_router.rs` | replaces `routes/chat.rs` |
| `patched/media.rs` | replaces the media service (adds `MediaCategory::ChatEncrypted`) |
| `patched/protocol.rs` | replaces gateway `src/protocol.rs` (adds `ServerEvent::SendFailed`) |
| `patched/session.rs` | replaces gateway `src/session.rs` (sends `SendFailed` when a socket send is rejected) |

## Dependencies
`base64 = "0.22"` in the core crate. `thiserror` and `sqlx` (json, uuid, chrono) are also required.

## Remaining manual steps
1. If another caller of `ChatService::edit_message` exists, pass the new last argument (`None`).
2. If the gateway re-parses published frames into a typed `ServerEvent`, make sure `message_edited` accepts
   `text_content: null` plus `e2ee_envelope` / `e2ee_ciphertexts`, and that `e2ee_enabled` passes through.
   Raw-JSON forwarding needs nothing.
3. Optional index for idempotent retries:
   `CREATE INDEX messages_e2ee_client_msg ON messages (conversation_id, sender_id, ((e2ee_envelope->>'client_msg_id'))) WHERE e2ee_envelope IS NOT NULL;`
4. Add an object-storage lifecycle rule on `chat/e2ee/` and keep write access for that prefix.
5. Call `purge_expired_ciphertexts` from your disappearing-message sweeper.
6. `cargo check` both crates. `ChatError::wire_error` is `pub` and used from the gateway.

## Behaviour

**Enabling.** Encryption is on by default. The first valid encrypted send to a plaintext chat switches it on (any
current member, 1:1 or group) and publishes `e2ee_enabled` to members. This only happens if the ciphertext set is
exactly right and every member has a registered device; otherwise 409 `e2ee/users-without-devices` and nothing
changes (the client then sends plaintext). One-way. `POST /conversations/{id}/e2ee/enable` also exists.

**Enforcement.** Once enabled, plaintext sends return **428** `e2ee/encryption-required`. Every user-authored
`content_type` (text, media, voice, location, view-once, disappearing) can be encrypted. An encrypted send must have
no `text_content`, `media_url`, or media metadata other than `view_duration_seconds` / `is_live_location`.
`E2EE_ALLOW_PLAINTEXT_UNSUPPORTED` (default `false`) lets an encrypted chat accept non-text plaintext during a
client rollout; messages sent that way are not end-to-end encrypted.

**Device set.** The send/edit ciphertext set must equal the active devices of current members minus the sending
device, else **409** `e2ee/devices-changed` (client refetches devices, re-encrypts, retries). A member with no device
gets no ciphertext and cannot read the message.

**Storage and delivery.** Encrypted messages store `text_content = NULL`. Every frame / REST message carries
`e2ee_envelope` and `e2ee_ciphertexts`, filtered to the receiving user's devices; the client picks its own `device_id`.
Retries with the same `client_msg_id` return the stored message. Unsend deletes the ciphertexts. Ciphertext reads
skip expired disappearing messages.

**Socket sends.** `SendMessage.request.e2ee` carries the ciphertexts. A rejected send produces
`{"type":"send_failed","conversation_id","client_temp_id","status","code","message"}` to the sender only.

**Previews and push.** `last_message_preview` is `""` for encrypted messages and the push body is "New message".
The client's notification extension replaces it by calling
`GET /conversations/{id}/messages/{message_id}/e2ee-push?device_id=` (auth: push-ack claims, same as
`push-ack-delivered`), which returns `{envelope, ciphertext, created_at}` for that user's device only (404 otherwise).
The push worker must keep `mutable-content: 1` and `conversation_id` / `message_id` in the payload.

**Attachments.** `MediaCategory::ChatEncrypted` stores blobs under `chat/e2ee/` as `.bin`
(`application/octet-stream`, 101 MB limit).

**Ephemeral frames.** `validate_ephemeral` checks a per-device ciphertext set and splits it by user
(`EphemeralE2ee`, `EphemeralE2eeOut` in `models_e2ee.rs`).
* `ClientMessage::LocationUpdateE2ee` -> `ServerEvent::LocationUpdateE2ee`: each recipient user (including the
  sender's other devices) gets only its own ciphertexts. Plaintext `LocationUpdate` in an encrypted chat is answered
  with `send_failed` (428).
* `CallSignal` in an encrypted chat requires `payload.e2ee` (except `type: "end"`), is validated, and is re-emitted as
  `{type, e2ee:{sender_device_id, ciphertexts for the callee}}`. Offer stash/replay keeps working (it stores the
  already-encrypted frame).

**Caveat.** A call or location ping in a chat that is not yet encrypted stays plaintext; encryption turns on with the
first message.
