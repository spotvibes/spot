-- SPDX-License-Identifier: AGPL-3.0
--
-- End-to-end encryption using the Signal protocol (PQXDH + Double Ratchet, libsignal).
-- The server stores public keys and opaque per-device ciphertexts only.

CREATE TABLE e2ee_devices (
    device_id             uuid PRIMARY KEY,
    user_id               uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name                  text NOT NULL DEFAULT '',
    registration_id       integer NOT NULL CHECK (registration_id BETWEEN 0 AND 16383),
    identity_key          bytea NOT NULL CHECK (octet_length(identity_key) = 33),
    signed_prekey_id      integer NOT NULL,
    signed_prekey         bytea NOT NULL,
    signed_prekey_sig     bytea NOT NULL CHECK (octet_length(signed_prekey_sig) = 64),
    kyber_last_resort_id  integer NOT NULL,
    kyber_last_resort     bytea NOT NULL,
    kyber_last_resort_sig bytea NOT NULL CHECK (octet_length(kyber_last_resort_sig) = 64),
    created_at            timestamptz NOT NULL DEFAULT now(),
    last_seen_at          timestamptz,
    revoked_at            timestamptz
);
CREATE INDEX e2ee_devices_user_active ON e2ee_devices (user_id) WHERE revoked_at IS NULL;

CREATE TABLE e2ee_one_time_prekeys (
    device_id  uuid NOT NULL REFERENCES e2ee_devices(device_id) ON DELETE CASCADE,
    prekey_id  integer NOT NULL,
    public_key bytea NOT NULL,
    PRIMARY KEY (device_id, prekey_id)
);

CREATE TABLE e2ee_one_time_kyber_prekeys (
    device_id  uuid NOT NULL REFERENCES e2ee_devices(device_id) ON DELETE CASCADE,
    prekey_id  integer NOT NULL,
    public_key bytea NOT NULL,
    signature  bytea NOT NULL CHECK (octet_length(signature) = 64),
    PRIMARY KEY (device_id, prekey_id)
);

-- Set once per conversation and never unset.
ALTER TABLE conversations
    ADD COLUMN e2ee_enabled    boolean NOT NULL DEFAULT false,
    ADD COLUMN e2ee_enabled_at timestamptz,
    ADD COLUMN e2ee_enabled_by uuid;

-- Envelope metadata: {"v":2,"sender_device_id","client_msg_id","rev"}. NULL = plaintext message.
ALTER TABLE messages ADD COLUMN e2ee_envelope jsonb;

-- One ciphertext per recipient device (including the sender's other devices).
-- msg_type: 2 = SignalMessage, 3 = PreKeySignalMessage. Replaced wholesale on edit.
CREATE TABLE message_device_ciphertexts (
    message_id uuid NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    device_id  uuid NOT NULL REFERENCES e2ee_devices(device_id) ON DELETE CASCADE,
    user_id    uuid NOT NULL,
    msg_type   smallint NOT NULL CHECK (msg_type IN (2, 3)),
    body       bytea NOT NULL,
    PRIMARY KEY (message_id, device_id)
);
CREATE INDEX message_device_ciphertexts_user ON message_device_ciphertexts (user_id, message_id);
