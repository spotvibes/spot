// SPDX-License-Identifier: AGPL-3.0

use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Deserialize)]
pub struct SignedPreKeyDto {
    pub id: i32,
    pub public_key: String,
    pub signature: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PreKeyDto {
    pub id: i32,
    pub public_key: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct KyberPreKeyDto {
    pub id: i32,
    pub public_key: String,
    pub signature: String,
}

#[derive(Debug, Deserialize)]
pub struct RegisterDeviceRequest {
    pub device_id: Uuid,
    #[serde(default)]
    pub name: String,
    pub registration_id: i32,
    pub identity_key: String,
    pub signed_prekey: SignedPreKeyDto,
    pub kyber_last_resort: SignedPreKeyDto,
    #[serde(default)]
    pub one_time_prekeys: Vec<PreKeyDto>,
    #[serde(default)]
    pub one_time_kyber_prekeys: Vec<KyberPreKeyDto>,
}

#[derive(Debug, Deserialize)]
pub struct UploadPreKeysRequest {
    #[serde(default)]
    pub one_time_prekeys: Vec<PreKeyDto>,
    #[serde(default)]
    pub one_time_kyber_prekeys: Vec<KyberPreKeyDto>,
}

#[derive(Debug, Deserialize)]
pub struct RotateSignedPreKeyRequest {
    pub signed_prekey: SignedPreKeyDto,
}

#[derive(Debug, Serialize)]
pub struct PreKeyCountResponse {
    pub one_time_prekeys: i64,
    pub one_time_kyber_prekeys: i64,
}

#[derive(Debug, Serialize, sqlx::FromRow)]
pub struct DeviceSummary {
    pub device_id: Uuid,
    pub name: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub last_seen_at: Option<chrono::DateTime<chrono::Utc>>,
}

#[derive(Debug, Serialize)]
pub struct ConversationDevice {
    pub user_id: Uuid,
    pub device_id: Uuid,
    pub registration_id: i32,
    pub identity_key: String,
}

#[derive(Debug, Serialize)]
pub struct ConversationDevicesResponse {
    pub devices: Vec<ConversationDevice>,
    pub users_without_devices: Vec<Uuid>,
}

#[derive(Debug, Serialize)]
pub struct ConversationE2eeState {
    pub enabled: bool,
    pub enabled_at: Option<chrono::DateTime<chrono::Utc>>,
    pub enabled_by: Option<Uuid>,
}

#[derive(Debug, Deserialize)]
pub struct PreKeyBundlesRequest {
    pub conversation_id: Uuid,
    pub device_ids: Vec<Uuid>,
}

#[derive(Debug, Serialize)]
pub struct BundleSignedPreKey {
    pub id: i32,
    pub public_key: String,
    pub signature: String,
}

#[derive(Debug, Serialize)]
pub struct BundlePreKey {
    pub id: i32,
    pub public_key: String,
}

#[derive(Debug, Serialize)]
pub struct PreKeyBundleDto {
    pub user_id: Uuid,
    pub device_id: Uuid,
    pub registration_id: i32,
    pub identity_key: String,
    pub signed_prekey: BundleSignedPreKey,
    pub prekey: Option<BundlePreKey>,
    pub kyber_prekey: BundleSignedPreKey,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CiphertextDto {
    pub device_id: Uuid,
    pub msg_type: i16,
    pub body: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct E2eeSendPayload {
    pub sender_device_id: Uuid,
    pub client_msg_id: Uuid,
    #[serde(default)]
    pub rev: i32,
    pub ciphertexts: Vec<CiphertextDto>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CiphertextOut {
    pub device_id: Uuid,
    pub msg_type: i16,
    pub body: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct PushCiphertextResponse {
    pub envelope: serde_json::Value,
    pub ciphertext: CiphertextOut,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EphemeralE2ee {
    pub sender_device_id: Uuid,
    pub ciphertexts: Vec<CiphertextDto>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EphemeralE2eeOut {
    pub sender_device_id: Uuid,
    pub ciphertexts: Vec<CiphertextOut>,
}
