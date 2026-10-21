// SPDX-License-Identifier: AGPL-3.0

use crate::models::chat::Message;
use crate::models::e2ee::*;
use crate::DbPools;
use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use std::collections::{HashMap, HashSet};
use uuid::Uuid;

const MAX_ACTIVE_DEVICES_PER_USER: i64 = 10;
const MAX_UPLOAD_BATCH: usize = 200;
const MAX_STORED_PREKEYS: i64 = 600;
const MAX_BUNDLES_PER_REQUEST: usize = 200;
const MAX_CIPHERTEXT_BYTES: usize = 128 * 1024;
const MAX_CIPHERTEXTS_PER_MESSAGE: usize = 2000;

#[derive(Debug, thiserror::Error)]
pub enum E2eeError {
    #[error("database error: {0}")]
    Db(#[from] sqlx::Error),
    #[error("not found")]
    NotFound,
    #[error("forbidden")]
    Forbidden,
    #[error("{0}")]
    Invalid(String),
    #[error("{0}")]
    Conflict(String),
    #[error("the recipient device list changed")]
    DevicesChanged,
    #[error("this conversation is end-to-end encrypted")]
    EncryptionRequired,
    #[error("encryption is not enabled for this conversation")]
    NotEnabled,
    #[error("some members have no registered devices")]
    UsersWithoutDevices(Vec<Uuid>),
}

impl E2eeError {
    pub fn wire(&self) -> (u16, &'static str, String) {
        match self {
            E2eeError::NotFound => (404, "e2ee/not-found", "Not found".into()),
            E2eeError::Forbidden => (403, "e2ee/forbidden", "Not allowed".into()),
            E2eeError::Invalid(m) => (400, "e2ee/invalid", m.clone()),
            E2eeError::Conflict(m) => (409, "e2ee/conflict", m.clone()),
            E2eeError::DevicesChanged => (409, "e2ee/devices-changed", "Recipient devices changed".into()),
            E2eeError::EncryptionRequired => (428, "e2ee/encryption-required", "This conversation is end-to-end encrypted".into()),
            E2eeError::NotEnabled => (409, "e2ee/not-enabled", "Encryption is not enabled for this conversation".into()),
            E2eeError::UsersWithoutDevices(_) => (409, "e2ee/users-without-devices", "Someone in this chat hasn't set up encryption yet".into()),
            E2eeError::Db(_) => (500, "e2ee/internal-error", "Something went wrong".into()),
        }
    }
}

fn dec(field: &str, s: &str, max: usize) -> Result<Vec<u8>, E2eeError> {
    let v = B64
        .decode(s)
        .map_err(|_| E2eeError::Invalid(format!("{field} is not valid base64")))?;
    if v.is_empty() || v.len() > max {
        return Err(E2eeError::Invalid(format!("{field} has an invalid length")));
    }
    Ok(v)
}

fn dec_exact(field: &str, s: &str, len: usize) -> Result<Vec<u8>, E2eeError> {
    let v = dec(field, s, len)?;
    if v.len() != len {
        return Err(E2eeError::Invalid(format!("{field} must be {len} bytes")));
    }
    Ok(v)
}

fn check_device_row(
    id: i32,
    key_field: &str,
    key: &str,
    sig: Option<&str>,
) -> Result<(Vec<u8>, Option<Vec<u8>>), E2eeError> {
    if id < 0 {
        return Err(E2eeError::Invalid("prekey id must be >= 0".into()));
    }
    let k = dec(key_field, key, 4096)?;
    let s = match sig {
        Some(s) => Some(dec_exact("signature", s, 64)?),
        None => None,
    };
    Ok((k, s))
}

async fn insert_one_time_prekeys(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    device_id: Uuid,
    keys: &[PreKeyDto],
) -> Result<(), E2eeError> {
    if keys.is_empty() {
        return Ok(());
    }
    if keys.len() > MAX_UPLOAD_BATCH {
        return Err(E2eeError::Invalid("too many prekeys in one upload".into()));
    }
    let mut ids = Vec::with_capacity(keys.len());
    let mut pubs: Vec<Vec<u8>> = Vec::with_capacity(keys.len());
    for k in keys {
        let (p, _) = check_device_row(k.id, "prekey", &k.public_key, None)?;
        ids.push(k.id);
        pubs.push(p);
    }
    sqlx::query(
        "INSERT INTO e2ee_one_time_prekeys (device_id, prekey_id, public_key) \
         SELECT $1::uuid, t.id, t.pk FROM UNNEST($2::int4[], $3::bytea[]) AS t(id, pk) \
         ON CONFLICT DO NOTHING",
    )
    .bind(device_id)
    .bind(&ids)
    .bind(&pubs)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

async fn insert_kyber_prekeys(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    device_id: Uuid,
    keys: &[KyberPreKeyDto],
) -> Result<(), E2eeError> {
    if keys.is_empty() {
        return Ok(());
    }
    if keys.len() > MAX_UPLOAD_BATCH {
        return Err(E2eeError::Invalid("too many kyber prekeys in one upload".into()));
    }
    let mut ids = Vec::with_capacity(keys.len());
    let mut pubs: Vec<Vec<u8>> = Vec::with_capacity(keys.len());
    let mut sigs: Vec<Vec<u8>> = Vec::with_capacity(keys.len());
    for k in keys {
        let (p, s) = check_device_row(k.id, "kyber prekey", &k.public_key, Some(&k.signature))?;
        ids.push(k.id);
        pubs.push(p);
        sigs.push(s.unwrap());
    }
    sqlx::query(
        "INSERT INTO e2ee_one_time_kyber_prekeys (device_id, prekey_id, public_key, signature) \
         SELECT $1::uuid, t.id, t.pk, t.sg FROM UNNEST($2::int4[], $3::bytea[], $4::bytea[]) AS t(id, pk, sg) \
         ON CONFLICT DO NOTHING",
    )
    .bind(device_id)
    .bind(&ids)
    .bind(&pubs)
    .bind(&sigs)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

pub async fn register_device(pools: &DbPools, user_id: Uuid, req: RegisterDeviceRequest) -> Result<(), E2eeError> {
    if !(0..=16383).contains(&req.registration_id) {
        return Err(E2eeError::Invalid("registration_id out of range".into()));
    }
    let identity = dec_exact("identity_key", &req.identity_key, 33)?;
    let (spk, spk_sig) = check_device_row(req.signed_prekey.id, "signed_prekey", &req.signed_prekey.public_key, Some(&req.signed_prekey.signature))?;
    let (klr, klr_sig) = check_device_row(req.kyber_last_resort.id, "kyber_last_resort", &req.kyber_last_resort.public_key, Some(&req.kyber_last_resort.signature))?;
    let name: String = req.name.chars().take(64).collect();

    let mut tx = pools.writer().begin().await?;
    let existing: Option<(Uuid, Vec<u8>, bool)> = sqlx::query_as(
        "SELECT user_id, identity_key, revoked_at IS NOT NULL FROM e2ee_devices WHERE device_id = $1 FOR UPDATE",
    )
    .bind(req.device_id)
    .fetch_optional(&mut *tx)
    .await?;

    match existing {
        Some((owner, _, _)) if owner != user_id => return Err(E2eeError::Forbidden),
        Some((_, _, true)) => return Err(E2eeError::Conflict("this device was revoked; register a new device".into())),
        Some((_, ik, _)) if ik != identity => {
            return Err(E2eeError::Conflict("identity key changed; register as a new device".into()))
        }
        Some(_) => {
            sqlx::query(
                "UPDATE e2ee_devices SET name = $2, signed_prekey_id = $3, signed_prekey = $4, signed_prekey_sig = $5, \
                 kyber_last_resort_id = $6, kyber_last_resort = $7, kyber_last_resort_sig = $8, last_seen_at = now() \
                 WHERE device_id = $1",
            )
            .bind(req.device_id)
            .bind(&name)
            .bind(req.signed_prekey.id)
            .bind(&spk)
            .bind(spk_sig.unwrap())
            .bind(req.kyber_last_resort.id)
            .bind(&klr)
            .bind(klr_sig.unwrap())
            .execute(&mut *tx)
            .await?;
        }
        None => {
            let active: i64 = sqlx::query_scalar(
                "SELECT count(*) FROM e2ee_devices WHERE user_id = $1 AND revoked_at IS NULL",
            )
            .bind(user_id)
            .fetch_one(&mut *tx)
            .await?;
            if active >= MAX_ACTIVE_DEVICES_PER_USER {
                return Err(E2eeError::Conflict("too many registered devices; remove one first".into()));
            }
            sqlx::query(
                "INSERT INTO e2ee_devices (device_id, user_id, name, registration_id, identity_key, \
                 signed_prekey_id, signed_prekey, signed_prekey_sig, kyber_last_resort_id, kyber_last_resort, \
                 kyber_last_resort_sig, last_seen_at) \
                 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11, now())",
            )
            .bind(req.device_id)
            .bind(user_id)
            .bind(&name)
            .bind(req.registration_id)
            .bind(&identity)
            .bind(req.signed_prekey.id)
            .bind(&spk)
            .bind(spk_sig.unwrap())
            .bind(req.kyber_last_resort.id)
            .bind(&klr)
            .bind(klr_sig.unwrap())
            .execute(&mut *tx)
            .await?;
        }
    }

    insert_one_time_prekeys(&mut tx, req.device_id, &req.one_time_prekeys).await?;
    insert_kyber_prekeys(&mut tx, req.device_id, &req.one_time_kyber_prekeys).await?;
    tx.commit().await?;
    Ok(())
}

async fn assert_active_device(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    user_id: Uuid,
    device_id: Uuid,
) -> Result<(), E2eeError> {
    let ok: Option<i32> = sqlx::query_scalar(
        "SELECT 1 FROM e2ee_devices WHERE device_id = $1 AND user_id = $2 AND revoked_at IS NULL FOR UPDATE",
    )
    .bind(device_id)
    .bind(user_id)
    .fetch_optional(&mut **tx)
    .await?;
    ok.map(|_| ()).ok_or(E2eeError::NotFound)
}

pub async fn upload_prekeys(pools: &DbPools, user_id: Uuid, device_id: Uuid, req: UploadPreKeysRequest) -> Result<PreKeyCountResponse, E2eeError> {
    let mut tx = pools.writer().begin().await?;
    assert_active_device(&mut tx, user_id, device_id).await?;
    let (otp, kyber) = counts_in(&mut tx, device_id).await?;
    if otp + kyber + (req.one_time_prekeys.len() + req.one_time_kyber_prekeys.len()) as i64 > MAX_STORED_PREKEYS * 2 {
        return Err(E2eeError::Invalid("too many prekeys stored".into()));
    }
    insert_one_time_prekeys(&mut tx, device_id, &req.one_time_prekeys).await?;
    insert_kyber_prekeys(&mut tx, device_id, &req.one_time_kyber_prekeys).await?;
    let (otp, kyber) = counts_in(&mut tx, device_id).await?;
    tx.commit().await?;
    Ok(PreKeyCountResponse { one_time_prekeys: otp, one_time_kyber_prekeys: kyber })
}

async fn counts_in(tx: &mut sqlx::Transaction<'_, sqlx::Postgres>, device_id: Uuid) -> Result<(i64, i64), E2eeError> {
    let otp: i64 = sqlx::query_scalar("SELECT count(*) FROM e2ee_one_time_prekeys WHERE device_id = $1")
        .bind(device_id)
        .fetch_one(&mut **tx)
        .await?;
    let kyber: i64 = sqlx::query_scalar("SELECT count(*) FROM e2ee_one_time_kyber_prekeys WHERE device_id = $1")
        .bind(device_id)
        .fetch_one(&mut **tx)
        .await?;
    Ok((otp, kyber))
}

pub async fn prekey_counts(pools: &DbPools, user_id: Uuid, device_id: Uuid) -> Result<PreKeyCountResponse, E2eeError> {
    let mut tx = pools.writer().begin().await?;
    assert_active_device(&mut tx, user_id, device_id).await?;
    let (otp, kyber) = counts_in(&mut tx, device_id).await?;
    sqlx::query("UPDATE e2ee_devices SET last_seen_at = now() WHERE device_id = $1")
        .bind(device_id)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(PreKeyCountResponse { one_time_prekeys: otp, one_time_kyber_prekeys: kyber })
}

pub async fn rotate_signed_prekey(pools: &DbPools, user_id: Uuid, device_id: Uuid, req: RotateSignedPreKeyRequest) -> Result<(), E2eeError> {
    let (spk, sig) = check_device_row(req.signed_prekey.id, "signed_prekey", &req.signed_prekey.public_key, Some(&req.signed_prekey.signature))?;
    let n = sqlx::query(
        "UPDATE e2ee_devices SET signed_prekey_id = $3, signed_prekey = $4, signed_prekey_sig = $5 \
         WHERE device_id = $1 AND user_id = $2 AND revoked_at IS NULL",
    )
    .bind(device_id)
    .bind(user_id)
    .bind(req.signed_prekey.id)
    .bind(&spk)
    .bind(sig.unwrap())
    .execute(pools.writer())
    .await?
    .rows_affected();
    if n == 0 {
        return Err(E2eeError::NotFound);
    }
    Ok(())
}

pub async fn list_devices(pools: &DbPools, user_id: Uuid) -> Result<Vec<DeviceSummary>, E2eeError> {
    Ok(sqlx::query_as::<_, DeviceSummary>(
        "SELECT device_id, name, created_at, last_seen_at FROM e2ee_devices \
         WHERE user_id = $1 AND revoked_at IS NULL ORDER BY created_at",
    )
    .bind(user_id)
    .fetch_all(pools.writer())
    .await?)
}

pub async fn revoke_device(pools: &DbPools, user_id: Uuid, device_id: Uuid) -> Result<(), E2eeError> {
    let mut tx = pools.writer().begin().await?;
    let n = sqlx::query("UPDATE e2ee_devices SET revoked_at = now() WHERE device_id = $1 AND user_id = $2 AND revoked_at IS NULL")
        .bind(device_id)
        .bind(user_id)
        .execute(&mut *tx)
        .await?
        .rows_affected();
    if n == 0 {
        return Err(E2eeError::NotFound);
    }
    sqlx::query("DELETE FROM e2ee_one_time_prekeys WHERE device_id = $1").bind(device_id).execute(&mut *tx).await?;
    sqlx::query("DELETE FROM e2ee_one_time_kyber_prekeys WHERE device_id = $1").bind(device_id).execute(&mut *tx).await?;
    tx.commit().await?;
    Ok(())
}

pub async fn member_user_ids(pools: &DbPools, conversation_id: Uuid) -> Result<Vec<Uuid>, E2eeError> {
    Ok(sqlx::query_scalar(
        r#"SELECT cp.participant_id
           FROM conversation_participants cp
           JOIN conversations c ON c.id = cp.conversation_id
           WHERE cp.conversation_id = $1
             AND cp.participant_type = 'user'
             AND cp.left_at IS NULL
             AND (NOT c.is_group OR cp.status = 'accepted')"#,
    )
    .bind(conversation_id)
    .fetch_all(pools.writer())
    .await?)
}

#[derive(sqlx::FromRow)]
struct DeviceRow {
    user_id: Uuid,
    device_id: Uuid,
    registration_id: i32,
    identity_key: Vec<u8>,
}

async fn active_devices_of(pools: &DbPools, user_ids: &[Uuid]) -> Result<Vec<DeviceRow>, E2eeError> {
    Ok(sqlx::query_as::<_, DeviceRow>(
        "SELECT user_id, device_id, registration_id, identity_key FROM e2ee_devices \
         WHERE user_id = ANY($1) AND revoked_at IS NULL ORDER BY user_id, created_at",
    )
    .bind(user_ids)
    .fetch_all(pools.writer())
    .await?)
}

pub async fn conversation_devices(pools: &DbPools, conversation_id: Uuid, caller_id: Uuid) -> Result<ConversationDevicesResponse, E2eeError> {
    let members = member_user_ids(pools, conversation_id).await?;
    if !members.contains(&caller_id) {
        return Err(E2eeError::Forbidden);
    }
    let rows = active_devices_of(pools, &members).await?;
    let with: HashSet<Uuid> = rows.iter().map(|r| r.user_id).collect();
    let users_without_devices = members.into_iter().filter(|u| !with.contains(u)).collect();
    let devices = rows
        .into_iter()
        .map(|r| ConversationDevice {
            user_id: r.user_id,
            device_id: r.device_id,
            registration_id: r.registration_id,
            identity_key: B64.encode(r.identity_key),
        })
        .collect();
    Ok(ConversationDevicesResponse { devices, users_without_devices })
}

pub async fn enable_conversation(pools: &DbPools, conversation_id: Uuid, caller_id: Uuid) -> Result<ConversationE2eeState, E2eeError> {
    let conv: Option<(bool, bool, Option<chrono::DateTime<chrono::Utc>>, Option<Uuid>)> = sqlx::query_as(
        "SELECT is_group, group_deleted_at IS NOT NULL, e2ee_enabled_at, e2ee_enabled_by \
         FROM conversations WHERE id = $1",
    )
    .bind(conversation_id)
    .fetch_optional(pools.writer())
    .await?;
    let (_is_group, deleted, enabled_at, enabled_by) = conv.ok_or(E2eeError::NotFound)?;
    if deleted {
        return Err(E2eeError::NotFound);
    }
    let members = member_user_ids(pools, conversation_id).await?;
    if !members.contains(&caller_id) {
        return Err(E2eeError::Forbidden);
    }
    if enabled_at.is_some() {
        return Ok(ConversationE2eeState { enabled: true, enabled_at, enabled_by });
    }
    let non_user: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM conversation_participants WHERE conversation_id = $1 AND left_at IS NULL AND participant_type <> 'user'",
    )
    .bind(conversation_id)
    .fetch_one(pools.writer())
    .await?;
    if non_user > 0 {
        return Err(E2eeError::Invalid("encryption isn't available in chats with service accounts".into()));
    }
    let with: HashSet<Uuid> = active_devices_of(pools, &members).await?.into_iter().map(|r| r.user_id).collect();
    let missing: Vec<Uuid> = members.into_iter().filter(|u| !with.contains(u)).collect();
    if !missing.is_empty() {
        return Err(E2eeError::UsersWithoutDevices(missing));
    }
    let row: (Option<chrono::DateTime<chrono::Utc>>, Option<Uuid>) = sqlx::query_as(
        "UPDATE conversations SET e2ee_enabled = TRUE, \
           e2ee_enabled_at = COALESCE(e2ee_enabled_at, now()), \
           e2ee_enabled_by = COALESCE(e2ee_enabled_by, $2) \
         WHERE id = $1 RETURNING e2ee_enabled_at, e2ee_enabled_by",
    )
    .bind(conversation_id)
    .bind(caller_id)
    .fetch_one(pools.writer())
    .await?;
    Ok(ConversationE2eeState { enabled: true, enabled_at: row.0, enabled_by: row.1 })
}

pub async fn prekey_bundles(pools: &DbPools, caller_id: Uuid, req: PreKeyBundlesRequest) -> Result<Vec<PreKeyBundleDto>, E2eeError> {
    if req.device_ids.len() > MAX_BUNDLES_PER_REQUEST {
        return Err(E2eeError::Invalid("too many devices requested".into()));
    }
    let members = member_user_ids(pools, req.conversation_id).await?;
    if !members.contains(&caller_id) {
        return Err(E2eeError::Forbidden);
    }
    let allowed: HashSet<Uuid> = active_devices_of(pools, &members).await?.into_iter().map(|r| r.device_id).collect();
    let wanted: Vec<Uuid> = {
        let mut seen = HashSet::new();
        req.device_ids.into_iter().filter(|d| seen.insert(*d)).collect()
    };
    if wanted.iter().any(|d| !allowed.contains(d)) {
        return Err(E2eeError::DevicesChanged);
    }

    #[derive(sqlx::FromRow)]
    struct Full {
        user_id: Uuid,
        registration_id: i32,
        identity_key: Vec<u8>,
        signed_prekey_id: i32,
        signed_prekey: Vec<u8>,
        signed_prekey_sig: Vec<u8>,
        kyber_last_resort_id: i32,
        kyber_last_resort: Vec<u8>,
        kyber_last_resort_sig: Vec<u8>,
    }

    let mut tx = pools.writer().begin().await?;
    let mut out = Vec::with_capacity(wanted.len());
    for device_id in wanted {
        let d: Full = sqlx::query_as(
            "SELECT user_id, registration_id, identity_key, signed_prekey_id, signed_prekey, signed_prekey_sig, \
             kyber_last_resort_id, kyber_last_resort, kyber_last_resort_sig \
             FROM e2ee_devices WHERE device_id = $1 AND revoked_at IS NULL",
        )
        .bind(device_id)
        .fetch_optional(&mut *tx)
        .await?
        .ok_or(E2eeError::DevicesChanged)?;

        let otp: Option<(i32, Vec<u8>)> = sqlx::query_as(
            "DELETE FROM e2ee_one_time_prekeys WHERE (device_id, prekey_id) IN ( \
               SELECT device_id, prekey_id FROM e2ee_one_time_prekeys WHERE device_id = $1 \
               ORDER BY prekey_id LIMIT 1 FOR UPDATE SKIP LOCKED) \
             RETURNING prekey_id, public_key",
        )
        .bind(device_id)
        .fetch_optional(&mut *tx)
        .await?;

        let kyber: Option<(i32, Vec<u8>, Vec<u8>)> = sqlx::query_as(
            "DELETE FROM e2ee_one_time_kyber_prekeys WHERE (device_id, prekey_id) IN ( \
               SELECT device_id, prekey_id FROM e2ee_one_time_kyber_prekeys WHERE device_id = $1 \
               ORDER BY prekey_id LIMIT 1 FOR UPDATE SKIP LOCKED) \
             RETURNING prekey_id, public_key, signature",
        )
        .bind(device_id)
        .fetch_optional(&mut *tx)
        .await?;

        let kyber_prekey = match kyber {
            Some((id, pk, sig)) => BundleSignedPreKey { id, public_key: B64.encode(pk), signature: B64.encode(sig) },
            None => BundleSignedPreKey {
                id: d.kyber_last_resort_id,
                public_key: B64.encode(&d.kyber_last_resort),
                signature: B64.encode(&d.kyber_last_resort_sig),
            },
        };
        out.push(PreKeyBundleDto {
            user_id: d.user_id,
            device_id,
            registration_id: d.registration_id,
            identity_key: B64.encode(&d.identity_key),
            signed_prekey: BundleSignedPreKey {
                id: d.signed_prekey_id,
                public_key: B64.encode(&d.signed_prekey),
                signature: B64.encode(&d.signed_prekey_sig),
            },
            prekey: otp.map(|(id, pk)| BundlePreKey { id, public_key: B64.encode(pk) }),
            kyber_prekey,
        });
    }
    tx.commit().await?;
    Ok(out)
}

pub async fn conversation_is_e2ee(pools: &DbPools, conversation_id: Uuid) -> Result<bool, E2eeError> {
    let v: Option<bool> = sqlx::query_scalar("SELECT e2ee_enabled FROM conversations WHERE id = $1")
        .bind(conversation_id)
        .fetch_optional(pools.writer())
        .await?;
    Ok(v.unwrap_or(false))
}

pub fn plaintext_allowed_for_unsupported() -> bool {
    static V: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *V.get_or_init(|| {
        std::env::var("E2EE_ALLOW_PLAINTEXT_UNSUPPORTED")
            .map(|v| matches!(v.trim().to_ascii_lowercase().as_str(), "1" | "true" | "yes" | "on"))
            .unwrap_or(false)
    })
}

pub async fn gate_and_validate(
    pools: &DbPools,
    conversation_id: Uuid,
    sender_id: Uuid,
    payload: Option<&E2eeSendPayload>,
    plaintext_ok: bool,
    auto_enable: bool,
) -> Result<(Option<HashMap<Uuid, Uuid>>, bool), E2eeError> {
    let enabled = conversation_is_e2ee(pools, conversation_id).await?;
    match (enabled, payload) {
        (false, None) => Ok((None, false)),
        (false, Some(p)) => {
            if !auto_enable {
                return Err(E2eeError::NotEnabled);
            }
            let fanout = validate_send(pools, conversation_id, sender_id, p).await?;
            enable_conversation(pools, conversation_id, sender_id).await?;
            Ok((Some(fanout), true))
        }
        (true, None) if plaintext_ok => Ok((None, false)),
        (true, None) => Err(E2eeError::EncryptionRequired),
        (true, Some(p)) => validate_send(pools, conversation_id, sender_id, p).await.map(|f| (Some(f), false)),
    }
}

pub async fn validate_send(
    pools: &DbPools,
    conversation_id: Uuid,
    sender_id: Uuid,
    p: &E2eeSendPayload,
) -> Result<HashMap<Uuid, Uuid>, E2eeError> {
    if p.ciphertexts.is_empty() || p.ciphertexts.len() > MAX_CIPHERTEXTS_PER_MESSAGE {
        return Err(E2eeError::Invalid("invalid ciphertext count".into()));
    }
    if p.rev < 0 {
        return Err(E2eeError::Invalid("invalid rev".into()));
    }
    for c in &p.ciphertexts {
        if c.msg_type != 2 && c.msg_type != 3 {
            return Err(E2eeError::Invalid("invalid msg_type".into()));
        }
        dec("ciphertext", &c.body, MAX_CIPHERTEXT_BYTES)?;
    }

    let members = member_user_ids(pools, conversation_id).await?;
    if !members.contains(&sender_id) {
        return Err(E2eeError::Forbidden);
    }
    let devices = active_devices_of(pools, &members).await?;
    if !devices.iter().any(|d| d.device_id == p.sender_device_id && d.user_id == sender_id) {
        return Err(E2eeError::Invalid("unknown or revoked sender device".into()));
    }
    let device_user: HashMap<Uuid, Uuid> = devices
        .iter()
        .filter(|d| d.device_id != p.sender_device_id)
        .map(|d| (d.device_id, d.user_id))
        .collect();

    let mut seen = HashSet::new();
    for c in &p.ciphertexts {
        if !seen.insert(c.device_id) {
            return Err(E2eeError::Invalid("duplicate ciphertext for a device".into()));
        }
    }
    let expected: HashSet<Uuid> = device_user.keys().copied().collect();
    if expected.is_empty() {
        return Err(E2eeError::Invalid("no recipient devices".into()));
    }
    if seen != expected {
        return Err(E2eeError::DevicesChanged);
    }
    Ok(device_user)
}

pub async fn push_ciphertext(
    pools: &DbPools,
    conversation_id: Uuid,
    message_id: Uuid,
    user_id: Uuid,
    device_id: Uuid,
) -> Result<Option<PushCiphertextResponse>, E2eeError> {
    let row: Option<(serde_json::Value, chrono::DateTime<chrono::Utc>, i16, Vec<u8>)> = sqlx::query_as(
        "SELECT m.e2ee_envelope, m.created_at, c.msg_type, c.body \
         FROM messages m JOIN message_device_ciphertexts c ON c.message_id = m.id \
         WHERE m.id = $1 AND m.conversation_id = $2 AND m.e2ee_envelope IS NOT NULL \
           AND c.user_id = $3 AND c.device_id = $4",
    )
    .bind(message_id)
    .bind(conversation_id)
    .bind(user_id)
    .bind(device_id)
    .fetch_optional(pools.writer())
    .await?;
    Ok(row.map(|(envelope, created_at, msg_type, body)| PushCiphertextResponse {
        envelope,
        ciphertext: CiphertextOut { device_id, msg_type, body: B64.encode(body) },
        created_at,
    }))
}

pub fn envelope_json(p: &E2eeSendPayload) -> serde_json::Value {
    serde_json::json!({
        "v": 2,
        "sender_device_id": p.sender_device_id,
        "client_msg_id": p.client_msg_id,
        "rev": p.rev,
    })
}

pub async fn store_ciphertexts(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    message_id: Uuid,
    p: &E2eeSendPayload,
    device_user: &HashMap<Uuid, Uuid>,
    replace: bool,
) -> Result<(), E2eeError> {
    if replace {
        sqlx::query("DELETE FROM message_device_ciphertexts WHERE message_id = $1")
            .bind(message_id)
            .execute(&mut **tx)
            .await?;
    }
    let mut devs = Vec::with_capacity(p.ciphertexts.len());
    let mut users = Vec::with_capacity(p.ciphertexts.len());
    let mut types: Vec<i16> = Vec::with_capacity(p.ciphertexts.len());
    let mut bodies: Vec<Vec<u8>> = Vec::with_capacity(p.ciphertexts.len());
    for c in &p.ciphertexts {
        let user = *device_user.get(&c.device_id).ok_or(E2eeError::DevicesChanged)?;
        devs.push(c.device_id);
        users.push(user);
        types.push(c.msg_type);
        bodies.push(dec("ciphertext", &c.body, MAX_CIPHERTEXT_BYTES)?);
    }
    sqlx::query(
        "INSERT INTO message_device_ciphertexts (message_id, device_id, user_id, msg_type, body) \
         SELECT $1::uuid, t.d, t.u, t.ty, t.b FROM UNNEST($2::uuid[], $3::uuid[], $4::int2[], $5::bytea[]) AS t(d, u, ty, b)",
    )
    .bind(message_id)
    .bind(&devs)
    .bind(&users)
    .bind(&types)
    .bind(&bodies)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

pub fn ciphertexts_by_user(p: &E2eeSendPayload, device_user: &HashMap<Uuid, Uuid>) -> HashMap<Uuid, Vec<CiphertextOut>> {
    let mut m: HashMap<Uuid, Vec<CiphertextOut>> = HashMap::new();
    for c in &p.ciphertexts {
        if let Some(u) = device_user.get(&c.device_id) {
            m.entry(*u).or_default().push(CiphertextOut { device_id: c.device_id, msg_type: c.msg_type, body: c.body.clone() });
        }
    }
    m
}

pub async fn validate_ephemeral(
    pools: &DbPools,
    conversation_id: Uuid,
    sender_id: Uuid,
    e: &EphemeralE2ee,
) -> Result<HashMap<Uuid, EphemeralE2eeOut>, E2eeError> {
    let p = E2eeSendPayload {
        sender_device_id: e.sender_device_id,
        client_msg_id: Uuid::nil(),
        rev: 0,
        ciphertexts: e.ciphertexts.clone(),
    };
    let device_user = validate_send(pools, conversation_id, sender_id, &p).await?;
    Ok(ciphertexts_by_user(&p, &device_user)
        .into_iter()
        .map(|(u, cts)| (u, EphemeralE2eeOut { sender_device_id: e.sender_device_id, ciphertexts: cts }))
        .collect())
}

pub async fn purge_expired_ciphertexts(pools: &DbPools) -> Result<u64, E2eeError> {
    let r = sqlx::query(
        "DELETE FROM message_device_ciphertexts c USING messages m \
         WHERE c.message_id = m.id AND m.is_disappearing AND m.expires_at IS NOT NULL AND m.expires_at <= now()",
    )
    .execute(pools.writer())
    .await?;
    Ok(r.rows_affected())
}

pub async fn ciphertexts_for_user(
    pools: &DbPools,
    message_ids: &[Uuid],
    user_id: Uuid,
) -> Result<HashMap<Uuid, Vec<CiphertextOut>>, E2eeError> {
    if message_ids.is_empty() {
        return Ok(HashMap::new());
    }
    let rows: Vec<(Uuid, Uuid, i16, Vec<u8>)> = sqlx::query_as(
        "SELECT message_id, device_id, msg_type, body FROM message_device_ciphertexts \
         WHERE message_id = ANY($1) AND user_id = $2 \
           AND NOT EXISTS (SELECT 1 FROM messages m WHERE m.id = message_id \
                           AND m.is_disappearing AND m.expires_at IS NOT NULL AND m.expires_at <= now())",
    )
    .bind(message_ids)
    .bind(user_id)
    .fetch_all(pools.reader())
    .await?;
    let mut m: HashMap<Uuid, Vec<CiphertextOut>> = HashMap::new();
    for (mid, device_id, msg_type, body) in rows {
        m.entry(mid).or_default().push(CiphertextOut { device_id, msg_type, body: B64.encode(body) });
    }
    Ok(m)
}

pub async fn find_by_client_msg_id(
    pools: &DbPools,
    conversation_id: Uuid,
    sender_id: Uuid,
    client_msg_id: Uuid,
) -> Result<Option<Message>, E2eeError> {
    Ok(sqlx::query_as::<_, Message>(
        "SELECT * FROM messages WHERE conversation_id = $1 AND sender_id = $2 \
         AND e2ee_envelope->>'client_msg_id' = $3 LIMIT 1",
    )
    .bind(conversation_id)
    .bind(sender_id)
    .bind(client_msg_id.to_string())
    .fetch_optional(pools.writer())
    .await?)
}
