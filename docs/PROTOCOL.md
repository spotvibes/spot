<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# Protocol summary

* libsignal (PQXDH + Double Ratchet); every install is its own device
  (`ProtocolAddress(name: lowercased device UUID, deviceId: 1)`).
* Pairwise per-device ciphertexts for groups and multi-device; the server
  validates the exact recipient device set (409 `e2ee/devices-changed`) and
  rejects plaintext in encrypted chats (428 `e2ee/encryption-required`).
* Payload JSON padded to 160-byte multiples; one decrypt per ciphertext, cached
  locally (ratchet keys are single use); app and notification extension
  serialised by a file lock.
* Attachments: AES-256-GCM, 256 KiB chunks, header `SPE1 | chunkSize | noncePrefix`,
  nonce = prefix || u32 index, AAD = header || final flag; key + SHA-256 digest
  travel inside the Signal ciphertext.
* Live location and call signalling: ephemeral per-device ciphertext frames.
* Safety numbers: 5200 rounds SHA-512 over identity keys + user id -> 60 digits.
