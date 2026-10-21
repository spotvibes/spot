// SPDX-License-Identifier: AGPL-3.0

use crate::CacheService;
use crate::DbPools;
use crate::models::chat::*;
use crate::notif_shared;
use crate::presence;
use crate::turn;
use crate::services::e2ee;
use crate::models::e2ee::{CiphertextOut, E2eeSendPayload};
use uuid::Uuid;
use chrono::{DateTime, Utc, Duration};

const BIT_UNOPENED_TTL: Duration = Duration::hours(24);
const BIT_OPENED_GRACE: Duration = Duration::seconds(10);

const LIVE_LOCATION_SAFETY_TTL: Duration = Duration::hours(9);

const CACHE_TTL_CONVERSATION_LIST: usize = 30;
const CACHE_BARRIER_TTL: usize = 10;
const MAX_MESSAGE_PAGE_SIZE: i64 = 100;
const DEFAULT_MESSAGE_PAGE_SIZE: i64 = 50;

const MESSAGE_DELETE_WINDOW: Duration = Duration::minutes(10);

const MESSAGE_EDIT_WINDOW: Duration = Duration::minutes(15);

const CACHE_TTL_ACTIVE_PARTICIPANTS: usize = 30;

fn message_for_user(
    m: &Message,
    per_user: Option<&std::collections::HashMap<Uuid, Vec<CiphertextOut>>>,
    user: Uuid,
) -> Message {
    let mut c = m.clone();
    if let Some(map) = per_user {
        c.e2ee_ciphertexts = Some(map.get(&user).cloned().unwrap_or_default());
    }
    c
}

#[derive(Debug, thiserror::Error)]
pub enum ChatError {
    #[error("database error: {0}")]
    Db(#[from] sqlx::Error),
    #[error("not a participant in this conversation")]
    NotParticipant,
    #[error("conversation request has not been accepted yet")]
    RequestNotAccepted,
    #[error("messaging is blocked between these participants")]
    Blocked,
    #[error("message not found or not owned by this sender")]
    NotFound,
    #[error("only a group creator can do this")]
    NotGroupCreator,
    #[error("this group has been deleted")]
    GroupDeleted,
    #[error("you have left this conversation")]
    LeftConversation,
    #[error("too many participants")]
    TooManyParticipants,
    #[error("invalid group request")]
    InvalidGroupRequest,
    #[error("this call has already ended")]
    CallEnded,
    #[error("too much time has passed to delete this message")]
    DeleteWindowExpired,
    #[error("too much time has passed to edit this message")]
    EditWindowExpired,
    #[error("message text cannot be empty")]
    EmptyMessage,
    #[error("You must follow {0} to send them a message")]
    FollowRequiredToMessage(String),
    #[error("You must follow {0} to add them to a group")]
    FollowRequiredToInvite(String),
    #[error("You can't add {0} to a group")]
    BlockedInvitees(String),
    #[error("{0}")]
    E2ee(#[from] e2ee::E2eeError),
}

impl ChatError {
    pub fn wire_error(&self) -> (u16, String, String) {
        match self {
            ChatError::E2ee(e) => {
                let (s, c, m) = e.wire();
                (s, c.to_string(), m)
            }
            ChatError::NotParticipant => (403, "chat/not-participant".into(), "Not a participant in this conversation".into()),
            ChatError::RequestNotAccepted => (403, "chat/request-not-accepted".into(), "Accept the conversation request before replying".into()),
            ChatError::Blocked => (403, "chat/blocked".into(), "Messaging is not available between these accounts".into()),
            ChatError::GroupDeleted => (410, "chat/group-deleted".into(), "This group has been deleted".into()),
            ChatError::LeftConversation => (403, "chat/left-conversation".into(), "You have left this conversation".into()),
            ChatError::FollowRequiredToMessage(_) => (403, "chat/follow-required-to-message".into(), self.to_string()),
            _ => (500, "chat/send-failed".into(), "Couldn't send this message".into()),
        }
    }
}

pub fn is_encryptable_request(req: &SendMessageRequest) -> bool {
    req.content_type != MessageContentType::System
}

fn e2ee_public_meta_ok(meta: &MessageMediaMetadata) -> bool {
    let mut v = match serde_json::to_value(meta) {
        Ok(v) => v,
        Err(_) => return false,
    };
    let Some(obj) = v.as_object_mut() else { return false };
    obj.retain(|_, x| !x.is_null());
    obj.keys().all(|k| k == "view_duration_seconds" || k == "is_live_location")
}

fn join_display_names(names: &[String]) -> String {
    match names {
        [] => String::new(),
        [only] => only.clone(),
        [a, b] => format!("{} and {}", a, b),
        [rest @ .., last] => format!("{} and {}", rest.join(", "), last),
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConversationView {
    Messages,
    Invitations,
    Archives,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ConversationKind {
    #[default]
    All,
    Direct,
    Group,
}

impl ConversationKind {
    pub fn from_query(value: Option<&str>) -> Self {
        match value {
            Some("direct") => ConversationKind::Direct,
            Some("group") => ConversationKind::Group,
            _ => ConversationKind::All,
        }
    }

    fn is_group_filter(self) -> Option<bool> {
        match self {
            ConversationKind::All => None,
            ConversationKind::Direct => Some(false),
            ConversationKind::Group => Some(true),
        }
    }
}

#[derive(Debug, Clone, sqlx::FromRow, serde::Serialize)]
pub struct ParticipantReadReceipt {
    pub user_id: Uuid,
    pub last_read_message_id: Option<Uuid>,
    pub last_read_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, sqlx::FromRow, serde::Serialize)]
pub struct MessageReceiptDetail {
    pub user_id: Uuid,
    pub delivered_at: Option<DateTime<Utc>>,
    pub opened_at: Option<DateTime<Utc>>,
}

#[derive(sqlx::FromRow)]
struct ConversationListRow {
    conversation_id: Uuid,
    other_participant_id: Option<Uuid>,
    other_participant_type: Option<ParticipantType>,
    other_username: Option<String>,
    other_chat_name: Option<String>,
    other_profile_image_url: Option<String>,
    other_online_status_visibility: Option<VisibilityLevel>,
    other_last_seen_visibility: Option<VisibilityLevel>,
    other_last_seen_at: Option<DateTime<Utc>>,
    is_following: bool,
    last_message_content_type: Option<MessageContentType>,
    last_message_text: Option<String>,
    last_message_at: Option<DateTime<Utc>>,
    last_message_sender_id: Option<Uuid>,
    last_message_delivered: Option<bool>,
    last_message_opened: Option<bool>,
    unread_count: i64,
    status: ParticipantStatus,
    other_status: Option<ParticipantStatus>,
    archived: bool,
    muted_until: Option<DateTime<Utc>>,
    is_group: bool,
    group_name: Option<String>,
    group_image_url: Option<String>,
    e2ee_enabled: bool,
}

fn conversation_row_to_summary(
    row: ConversationListRow,
    caller_id: Uuid,
    presence_map: &std::collections::HashMap<Uuid, presence::PresenceEntry>,
    blocks: &notif_shared::ChatBlockLookup,
    hidden_ids: &std::collections::HashSet<Uuid>,
) -> ConversationSummary {
    let other_is_hidden = !row.is_group
        && matches!(row.other_participant_type, Some(ParticipantType::User))
        && row.other_participant_id.map_or(false, |id| hidden_ids.contains(&id));

    if other_is_hidden {
        return ConversationSummary {
            conversation_id: row.conversation_id,
            e2ee_enabled: row.e2ee_enabled,
            is_group: false,
            group_name: None,
            group_image_url: None,
            other_participant_id: row.other_participant_id.unwrap_or(caller_id),
            other_participant_type: row.other_participant_type.unwrap_or(ParticipantType::User),
            display_name: "User not found".to_string(),
            username: None,
            is_following: true,
            last_message_preview: match row.last_message_content_type {
                Some(MessageContentType::Bit) => "sent a bit".to_string(),
                Some(MessageContentType::Image) => "sent a photo".to_string(),
                Some(MessageContentType::Video) => "sent a video".to_string(),
                Some(MessageContentType::Voice) => "sent a voice message".to_string(),
                Some(MessageContentType::Location) => "shared a location".to_string(),
                Some(MessageContentType::File) => "sent a file".to_string(),
                _ => row.last_message_text.clone().unwrap_or_default(),
            },
            last_message_content_type: row.last_message_content_type,
            last_message_at: row.last_message_at,
            last_message_sender_id: row.last_message_sender_id,
            last_message_delivered: row.last_message_sender_id == Some(caller_id) && row.last_message_delivered.unwrap_or(false),
            last_message_opened: row.last_message_sender_id == Some(caller_id) && row.last_message_opened.unwrap_or(false),
            unread_count: row.unread_count,
            status: row.status,
            profile_image_url: None,
            other_status: row.other_status.unwrap_or(ParticipantStatus::Accepted),
            archived: row.archived,
            muted_until: row.muted_until,
            presence: PresenceInfo::default(),
            is_blocked: false,
        };
    }

    let preview = match row.last_message_content_type {
        Some(MessageContentType::Bit) => "sent a bit".to_string(),
        Some(MessageContentType::Image) => "sent a photo".to_string(),
        Some(MessageContentType::Video) => "sent a video".to_string(),
        Some(MessageContentType::Voice) => "sent a voice message".to_string(),
        Some(MessageContentType::Location) => "shared a location".to_string(),
        Some(MessageContentType::File) => "sent a file".to_string(),
        _ => row.last_message_text.clone().unwrap_or_default(),
    };

    let display_name = if row.is_group {
        row.group_name.clone().unwrap_or_else(|| "Group".to_string())
    } else {
        row.other_chat_name
            .filter(|n| !n.trim().is_empty())
            .or(row.other_username.clone())
            .unwrap_or_else(|| row.other_participant_id.map(|id| id.to_string()).unwrap_or_default())
    };

    let presence = if row.is_group || row.other_participant_id.map_or(false, |id| blocks.blocked_either.contains(&id)) {
        PresenceInfo::default()
    } else {
        let entry = row.other_participant_id.and_then(|id| presence_map.get(&id));
        ChatService::visible_presence(
            row.other_online_status_visibility.unwrap_or_default(),
            row.other_last_seen_visibility.unwrap_or_default(),
            row.is_following,
            entry.map(|e| e.online).unwrap_or(false),
            entry.map(|e| e.last_seen).or(row.other_last_seen_at),
        )
    };

    ConversationSummary {
        conversation_id: row.conversation_id,
        e2ee_enabled: row.e2ee_enabled,
        is_group: row.is_group,
        group_name: row.group_name,
        group_image_url: row.group_image_url,
        other_participant_id: row.other_participant_id.unwrap_or(caller_id),
        other_participant_type: row.other_participant_type.unwrap_or(ParticipantType::User),
        display_name,
        username: row.other_username,
        is_following: row.is_group
            || row.other_participant_type == Some(ParticipantType::Service)
            || row.is_following,
        last_message_preview: preview,
        last_message_content_type: row.last_message_content_type,
        last_message_at: row.last_message_at,
        last_message_sender_id: row.last_message_sender_id,
        last_message_delivered: row.last_message_sender_id == Some(caller_id) && row.last_message_delivered.unwrap_or(false),
        last_message_opened: row.last_message_sender_id == Some(caller_id) && row.last_message_opened.unwrap_or(false),
        unread_count: row.unread_count,
        status: row.status,
        profile_image_url: row.other_profile_image_url,
        other_status: row.other_status.unwrap_or(ParticipantStatus::Accepted),
        archived: row.archived,
        muted_until: row.muted_until,
        presence,
        is_blocked: row.other_participant_id.map_or(false, |id| blocks.blocked_by_me.contains(&id)),
    }
}

pub fn encode_conversation_cursor(created_at: DateTime<Utc>, conversation_id: Uuid) -> String {
    format!(
        "{}.{}_{}",
        created_at.timestamp(),
        created_at.timestamp_subsec_nanos(),
        conversation_id
    )
}

pub fn decode_conversation_cursor(cursor: &str) -> Option<(DateTime<Utc>, Uuid)> {
    let (ts_part, id_part) = cursor.rsplit_once('_')?;
    let (secs, nanos) = ts_part.split_once('.')?;
    let secs: i64 = secs.parse().ok()?;
    let nanos: u32 = nanos.parse().ok()?;
    let ts = DateTime::<Utc>::from_timestamp(secs, nanos)?;
    let id = Uuid::parse_str(id_part).ok()?;
    Some((ts, id))
}

fn schedule_unacked_push_guards(
    cache: CacheService,
    message_id: Uuid,
    pending: Vec<(Uuid, notif_shared::NotificationEvent)>,
) {
    if pending.is_empty() {
        return;
    }
    actix_web::rt::spawn(async move {
        for (recipient_id, event) in pending {
            let job = notif_shared::DeliveryGuardJob { message_id, recipient_id, event };
            if !notif_shared::schedule_delivery_guard(&cache, &job).await {
                log::warn!("send_message: couldn't queue delivery guard for {} / message {}, pushing now", recipient_id, message_id);
                if let Err(e) = notif_shared::publish_event(&cache, &job.event).await {
                    log::error!("send_message: failed to publish notification event: {}", e);
                }
            }
        }
    });
}

const INBOX_MAXLEN: usize = 500;
const INBOX_TTL_SECS: i64 = 7 * 24 * 3600;
const INBOX_REPLAY_LIMIT: usize = 100;

fn inbox_key(user_id: Uuid) -> String {
    format!("inbox:{}", user_id)
}

async fn append_inbox(
    cache: &CacheService,
    recipient_id: Uuid,
    conversation_id: Uuid,
    message_id: Uuid,
    seq: i64,
) -> Option<String> {
    let mut conn = cache.client.clone();
    let key = inbox_key(recipient_id);
    let res: Result<(String,), redis::RedisError> = redis::pipe()
        .atomic()
        .cmd("XADD").arg(&key)
        .arg("MAXLEN").arg("~").arg(INBOX_MAXLEN)
        .arg("*")
        .arg("c").arg(conversation_id.to_string())
        .arg("m").arg(message_id.to_string())
        .arg("s").arg(seq)
        .cmd("EXPIRE").arg(&key).arg(INBOX_TTL_SECS).ignore()
        .query_async(&mut conn)
        .await;
    res.ok().map(|(id,)| id)
}

fn unacked_push_in_gateway() -> bool {
    static MODE: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *MODE.get_or_init(|| {
        std::env::var("UNACKED_PUSH_MODE").map(|v| v != "queue").unwrap_or(true)
    })
}

pub struct ChatService {
    cache: CacheService,
}

impl ChatService {
    pub fn new(cache: CacheService) -> Self {
        Self { cache }
    }

    pub async fn can_message(
        &self,
        pools: &DbPools,
        a_id: Uuid,
        b_id: Uuid,
    ) -> Result<bool, sqlx::Error> {
        Ok(!self.block_lookup(pools, a_id, &[b_id]).await?.blocked_either.contains(&b_id))
    }

    async fn block_lookup(
        &self,
        pools: &DbPools,
        user_id: Uuid,
        candidate_ids: &[Uuid],
    ) -> Result<notif_shared::ChatBlockLookup, sqlx::Error> {
        notif_shared::get_chat_block_lookup(&self.cache, pools, user_id, candidate_ids).await
    }

    async fn ensure_recipient_active(&self, other_id: Uuid, other_type: ParticipantType) -> Result<(), ChatError> {
        if !matches!(other_type, ParticipantType::User) {
            return Ok(());
        }
        let hidden = self.cache.content_hidden_subset(&[other_id.to_string()]).await;
        if hidden.contains(&other_id.to_string()) {
            return Err(ChatError::NotFound);
        }
        Ok(())
    }

    async fn ensure_sender_follows_for_dm(
        &self,
        pools: &DbPools,
        sender_id: Uuid,
        recipient_id: Uuid,
    ) -> Result<(), ChatError> {
        let blocked_by: Option<String> = sqlx::query_scalar(
            r#"
            SELECT COALESCE(u.chat_name, u.username)
            FROM users u
            WHERE u.id = $1
              AND u.chats_from_followers_only
              AND NOT EXISTS (
                  SELECT 1 FROM follows f
                  WHERE f.follower_id = $2 AND f.following_id = u.id
              )
            "#,
        )
        .bind(recipient_id)
        .bind(sender_id)
        .fetch_optional(pools.writer())
        .await?;

        match blocked_by {
            Some(name) => Err(ChatError::FollowRequiredToMessage(name)),
            None => Ok(()),
        }
    }

    async fn ensure_no_block_for_group(
        &self,
        pools: &DbPools,
        inviter_id: Uuid,
        invitee_ids: &[Uuid],
    ) -> Result<(), ChatError> {
        if invitee_ids.is_empty() {
            return Ok(());
        }
        let lookup = self.block_lookup(pools, inviter_id, invitee_ids).await?;
        let blocked: Vec<Uuid> = invitee_ids
            .iter()
            .copied()
            .filter(|id| lookup.blocked_either.contains(id))
            .collect();
        if blocked.is_empty() {
            return Ok(());
        }

        let names: Vec<String> = sqlx::query_scalar(
            r#"
            SELECT COALESCE(u.chat_name, u.username)
            FROM users u
            WHERE u.id = ANY($1)
            ORDER BY u.username
            "#,
        )
        .bind(&blocked)
        .fetch_all(pools.reader())
        .await?;

        Err(ChatError::BlockedInvitees(join_display_names(&names)))
    }

    async fn ensure_inviter_follows_for_group(
        &self,
        pools: &DbPools,
        inviter_id: Uuid,
        invitee_ids: &[Uuid],
    ) -> Result<(), ChatError> {
        if invitee_ids.is_empty() {
            return Ok(());
        }
        let blocked_by: Vec<String> = sqlx::query_scalar(
            r#"
            SELECT COALESCE(u.chat_name, u.username)
            FROM users u
            WHERE u.id = ANY($1)
              AND u.group_invites_from_followers_only
              AND NOT EXISTS (
                  SELECT 1 FROM follows f
                  WHERE f.follower_id = $2 AND f.following_id = u.id
              )
            ORDER BY u.username
            "#,
        )
        .bind(invitee_ids)
        .bind(inviter_id)
        .fetch_all(pools.writer())
        .await?;

        if blocked_by.is_empty() {
            Ok(())
        } else {
            Err(ChatError::FollowRequiredToInvite(join_display_names(&blocked_by)))
        }
    }

    async fn recipient_already_connected(
        &self,
        pools: &DbPools,
        recipient_id: Uuid,
        recipient_type: ParticipantType,
        sender_id: Uuid,
        sender_type: ParticipantType,
    ) -> bool {
        let user_follows_service = |user_id: Uuid, service_id: Uuid| async move {
            matches!(
                self.cache.is_following_service(&user_id.to_string(), &service_id.to_string()).await,
                Ok(Some(true))
            )
        };
        let user_follows_user = |follower: Uuid, followed: Uuid| async move {
            sqlx::query_scalar::<_, bool>(
                "SELECT EXISTS(SELECT 1 FROM follows WHERE follower_id = $1 AND following_id = $2)",
            )
            .bind(follower)
            .bind(followed)
            .fetch_one(pools.writer())
            .await
            .unwrap_or(false)
        };

        match (recipient_type, sender_type) {
            (ParticipantType::User, ParticipantType::User) => {
                user_follows_user(sender_id, recipient_id).await
            }
            (ParticipantType::User, ParticipantType::Service) => {
                user_follows_service(recipient_id, sender_id).await
            }
            (ParticipantType::Service, ParticipantType::User) => {
                user_follows_service(sender_id, recipient_id).await
            }
            (ParticipantType::Service, ParticipantType::Service) => false,
        }
    }

    pub async fn get_or_create_direct(
        &self,
        pools: &DbPools,
        caller_id: Uuid,
        caller_type: ParticipantType,
        other_id: Uuid,
        other_type: ParticipantType,
    ) -> Result<(Conversation, ParticipantStatus, ParticipantStatus), ChatError> {
        if !self.can_message(pools, caller_id, other_id).await? {
            return Err(ChatError::Blocked);
        }

        self.ensure_recipient_active(other_id, other_type).await?;

        if let Some(existing) = self.find_direct_conversation(pools, caller_id, other_id).await? {
            if let Some((my_status, other_status)) = self
                .claim_empty_direct_thread(pools, existing.id, caller_id, caller_type)
                .await?
            {
                return Ok((existing, other_status, my_status));
            }
            self.ensure_caller_row_accepted_and_visible(pools, existing.id, caller_id).await?;
            let other_status = self
                .get_participant_row(pools, existing.id, other_id)
                .await
                .map(|r| r.status)
                .unwrap_or(ParticipantStatus::Accepted);
            let my_status = self
                .get_participant_row(pools, existing.id, caller_id)
                .await
                .map(|r| r.status)
                .unwrap_or(ParticipantStatus::Accepted);
            return Ok((existing, other_status, my_status));
        }

        if matches!(caller_type, ParticipantType::User) && matches!(other_type, ParticipantType::User) {
            self.ensure_sender_follows_for_dm(pools, caller_id, other_id).await?;
        }

        let mut tx = pools.writer().begin().await?;

        let conversation = sqlx::query_as::<_, Conversation>(
            "INSERT INTO conversations (is_group) VALUES (FALSE) RETURNING *",
        )
        .fetch_one(&mut *tx)
        .await?;

        sqlx::query(
            r#"
            INSERT INTO conversation_participants
                (conversation_id, participant_id, participant_type, status)
            VALUES ($1, $2, $3, 'accepted')
            "#,
        )
        .bind(conversation.id)
        .bind(caller_id)
        .bind(caller_type)
        .execute(&mut *tx)
        .await?;

        let other_accepted = self
            .recipient_already_connected(pools, other_id, other_type, caller_id, caller_type)
            .await;
        let other_status = if other_accepted { ParticipantStatus::Accepted } else { ParticipantStatus::Pending };

        sqlx::query(
            r#"
            INSERT INTO conversation_participants
                (conversation_id, participant_id, participant_type, status)
            VALUES ($1, $2, $3, $4)
            "#,
        )
        .bind(conversation.id)
        .bind(other_id)
        .bind(other_type)
        .bind(other_status)
        .execute(&mut *tx)
        .await?;

        tx.commit().await?;

        self.invalidate_conversation_list_caches(&[caller_id, other_id]).await;
        Ok((conversation, other_status, ParticipantStatus::Accepted))
    }

    async fn claim_empty_direct_thread(
        &self,
        pools: &DbPools,
        conversation_id: Uuid,
        initiator_id: Uuid,
        initiator_type: ParticipantType,
    ) -> Result<Option<(ParticipantStatus, ParticipantStatus)>, ChatError> {
        let other: Option<(Uuid, ParticipantType)> = sqlx::query_as(
            r#"
            SELECT other.participant_id, other.participant_type
            FROM conversations c
            JOIN conversation_participants other
              ON other.conversation_id = c.id AND other.participant_id <> $2
            WHERE c.id = $1
              AND c.is_group = FALSE
              AND c.last_message_id IS NULL
              AND NOT EXISTS (SELECT 1 FROM messages m WHERE m.conversation_id = c.id)
            LIMIT 1
            "#,
        )
        .bind(conversation_id)
        .bind(initiator_id)
        .fetch_optional(pools.writer())
        .await?;
        let Some((other_id, other_type)) = other else {
            return Ok(None);
        };

        let other_connected = self
            .recipient_already_connected(pools, other_id, other_type, initiator_id, initiator_type)
            .await;
        let other_status = if other_connected { ParticipantStatus::Accepted } else { ParticipantStatus::Pending };

        let mine = sqlx::query(
            r#"
            UPDATE conversation_participants
            SET status = 'accepted', deleted_at = NULL
            WHERE conversation_id = $1 AND participant_id = $2
              AND (status != 'accepted' OR deleted_at IS NOT NULL)
            "#,
        )
        .bind(conversation_id)
        .bind(initiator_id)
        .execute(pools.writer())
        .await?;
        let theirs = sqlx::query(
            r#"
            UPDATE conversation_participants
            SET status = $3
            WHERE conversation_id = $1 AND participant_id = $2
              AND status != $3
            "#,
        )
        .bind(conversation_id)
        .bind(other_id)
        .bind(other_status)
        .execute(pools.writer())
        .await?;

        if mine.rows_affected() > 0 || theirs.rows_affected() > 0 {
            self.invalidate_conversation_list_caches(&[initiator_id, other_id]).await;
        }
        Ok(Some((ParticipantStatus::Accepted, other_status)))
    }

    async fn ensure_caller_row_accepted_and_visible(
        &self,
        pools: &DbPools,
        conversation_id: Uuid,
        caller_id: Uuid,
    ) -> Result<(), ChatError> {
        let updated = sqlx::query(
            r#"
            UPDATE conversation_participants
            SET status = 'accepted', deleted_at = NULL
            WHERE conversation_id = $1 AND participant_id = $2
              AND deleted_at IS NOT NULL
            "#,
        )
        .bind(conversation_id)
        .bind(caller_id)
        .execute(pools.writer())
        .await?;

        if updated.rows_affected() > 0 {
            self.invalidate_conversation_list_caches(&[caller_id]).await;
        }
        Ok(())
    }

    async fn find_direct_conversation(
        &self,
        pools: &DbPools,
        a_id: Uuid,
        b_id: Uuid,
    ) -> Result<Option<Conversation>, sqlx::Error> {
        sqlx::query_as::<_, Conversation>(
            r#"
            SELECT c.* FROM conversations c
            WHERE c.is_group = FALSE
              AND EXISTS (
                  SELECT 1 FROM conversation_participants p1
                  WHERE p1.conversation_id = c.id AND p1.participant_id = $1
              )
              AND EXISTS (
                  SELECT 1 FROM conversation_participants p2
                  WHERE p2.conversation_id = c.id AND p2.participant_id = $2
              )
            LIMIT 1
            "#,
        )
        .bind(a_id)
        .bind(b_id)
        .fetch_optional(pools.reader())
        .await
    }

    pub async fn unread_summary(&self, pools: &DbPools, caller_id: Uuid) -> Result<(i64, i64), sqlx::Error> {
        let messages_unread: i64 = sqlx::query_scalar(
    r#"
    SELECT COALESCE(SUM(
        (SELECT COUNT(*) FROM messages um
         WHERE um.conversation_id = me.conversation_id
           AND um.sender_id != $1
           AND um.deleted_at IS NULL
           AND (me.last_read_message_id IS NULL OR um.created_at > (
               SELECT created_at FROM messages WHERE id = me.last_read_message_id
           )))
    )::BIGINT, 0)
    FROM conversation_participants me
    WHERE me.participant_id = $1
      AND me.deleted_at IS NULL
      AND me.archived = FALSE
      AND me.status = 'accepted'
      AND (me.muted_until IS NULL OR me.muted_until <= now())
    "#,
        )
        .bind(caller_id)
        .fetch_one(pools.reader())
        .await?;

        let requests_unread: i64 = sqlx::query_scalar(
            r#"
            SELECT COUNT(*) FROM conversation_participants me
            WHERE me.participant_id = $1
              AND me.deleted_at IS NULL
              AND me.archived = FALSE
              AND me.status = 'pending'
              AND EXISTS (
                  SELECT 1 FROM conversations c
                  WHERE c.id = me.conversation_id AND c.last_message_id IS NOT NULL
              )
            "#,
        )
        .bind(caller_id)
        .fetch_one(pools.reader())
        .await?;

        Ok((messages_unread, requests_unread))
    }

    pub async fn list_conversations(
        &self,
        pools: &DbPools,
        caller_id: Uuid,
        view: ConversationView,
        page: i64,
        page_size: i64,
        exclude_left_groups: bool,
        kind: ConversationKind,
    ) -> Result<Vec<ConversationSummary>, sqlx::Error> {
        let cache_key = format!(
            "chat:conv_list:{}:{:?}:{}:{}:{}:{:?}",
            caller_id, view, page, page_size, exclude_left_groups, kind
        );
        if let Ok(Some(cached)) = self.cache.get::<Vec<ConversationSummary>>(&cache_key).await {
            return Ok(cached);
        }

        let query_started_at = Utc::now();

        let (status_filter, archived_filter): (Option<ParticipantStatus>, bool) = match view {
            ConversationView::Messages => (Some(ParticipantStatus::Accepted), false),
            ConversationView::Invitations => (Some(ParticipantStatus::Pending), false),
            ConversationView::Archives => (None, true),
        };

        let rows = sqlx::query_as::<_, ConversationListRow>(
            r#"
            SELECT
                me.conversation_id,
                other.participant_id      AS other_participant_id,
                other.participant_type    AS other_participant_type,
                u.username                 AS other_username,
                u.chat_name                AS other_chat_name,
                u.profile_image_url        AS other_profile_image_url,
                u.online_status_visibility AS other_online_status_visibility,
                u.last_seen_visibility     AS other_last_seen_visibility,
                u.last_seen_at             AS other_last_seen_at,
                COALESCE(EXISTS(
                    SELECT 1 FROM follows f
                    WHERE f.follower_id = $1 AND f.following_id = other.participant_id
                ), false) AS is_following,
                m.content_type            AS last_message_content_type,
                m.text_content            AS last_message_text,
                m.created_at              AS last_message_at,
                m.sender_id               AS last_message_sender_id,
                CASE WHEN m.content_type = 'bit' THEN EXISTS (
                    SELECT 1 FROM message_receipts mr
                    WHERE mr.message_id = m.id
                      AND mr.user_id != m.sender_id
                      AND mr.delivered_at IS NOT NULL
                ) ELSE (m.seq IS NOT NULL AND EXISTS (
                    SELECT 1 FROM conversation_participants rcp
                    WHERE rcp.conversation_id = m.conversation_id
                      AND rcp.participant_id != m.sender_id
                      AND rcp.last_delivered_seq >= m.seq
                )) END AS last_message_delivered,
                CASE WHEN m.content_type = 'bit' THEN EXISTS (
                    SELECT 1 FROM message_receipts mr
                    LEFT JOIN users rdr ON rdr.id = mr.user_id
                    LEFT JOIN users snd ON snd.id = m.sender_id
                    WHERE mr.message_id = m.id
                      AND mr.user_id != m.sender_id
                      AND mr.opened_at IS NOT NULL
                      AND (c.is_group OR (COALESCE(rdr.read_receipts_enabled, TRUE) AND COALESCE(snd.read_receipts_enabled, TRUE)))
                ) ELSE (m.seq IS NOT NULL AND EXISTS (
                    SELECT 1 FROM conversation_participants rcp
                    LEFT JOIN users rdr ON rdr.id = rcp.participant_id
                    LEFT JOIN users snd ON snd.id = m.sender_id
                    WHERE rcp.conversation_id = m.conversation_id
                      AND rcp.participant_id != m.sender_id
                      AND rcp.last_read_seq >= m.seq
                      AND (c.is_group OR (COALESCE(rdr.read_receipts_enabled, TRUE) AND COALESCE(snd.read_receipts_enabled, TRUE)))
                )) END AS last_message_opened,
                (
                    SELECT COUNT(*) FROM messages um
                    WHERE um.conversation_id = c.id
                      AND um.sender_id != $1
                      AND um.content_type != 'system'
                      AND um.deleted_at IS NULL
                      AND (me.last_read_message_id IS NULL OR um.created_at > (
                          SELECT created_at FROM messages WHERE id = me.last_read_message_id
                      ))
                      AND (me.left_at IS NULL OR um.created_at <= me.left_at)
                ) AS unread_count,
                me.status,
                other.status               AS other_status,
                me.archived,
                CASE WHEN me.muted_until IS NOT NULL AND me.muted_until <= now() THEN NULL ELSE me.muted_until END AS muted_until,
                c.is_group,
                c.group_name,
                c.group_image_url,
                c.e2ee_enabled
            FROM conversation_participants me
            JOIN conversations c ON c.id = me.conversation_id
            LEFT JOIN conversation_participants other
                ON other.conversation_id = me.conversation_id
               AND other.participant_id != me.participant_id
               AND c.is_group = false
            LEFT JOIN users u ON u.id = other.participant_id AND other.participant_type = 'user'
            LEFT JOIN LATERAL (
                SELECT lm.* FROM messages lm
                WHERE lm.conversation_id = c.id
                  AND lm.deleted_at IS NULL
                  AND (me.left_at IS NULL OR lm.created_at <= me.left_at)
                ORDER BY lm.created_at DESC, lm.id DESC
                LIMIT 1
            ) m ON true
            WHERE me.participant_id = $1
              AND me.deleted_at IS NULL
              AND me.archived = $2
              AND ($3::text IS NULL OR me.status = $3::text)
              AND c.last_message_id IS NOT NULL
              AND ($6 = false OR c.is_group = false OR me.left_at IS NULL)
              AND ($7::boolean IS NULL OR c.is_group = $7::boolean)
            ORDER BY m.created_at DESC NULLS LAST, c.id DESC
            OFFSET $4 LIMIT $5
            "#,
        )
        .bind(caller_id)
        .bind(archived_filter)
        .bind(status_filter.map(|s| match s { ParticipantStatus::Accepted => "accepted", ParticipantStatus::Pending => "pending" }))
        .bind(page * page_size)
        .bind(page_size.min(100))
        .bind(exclude_left_groups)
        .bind(kind.is_group_filter())
        .fetch_all(pools.reader())
        .await?;

        let online_ids: Vec<Uuid> = rows.iter().filter_map(|r| r.other_participant_id).collect();
        let presence_map = self.bulk_presence(&online_ids).await;
        let blocks = self.block_lookup(pools, caller_id, &online_ids).await?;
        let online_id_strs: Vec<String> = online_ids.iter().map(|id| id.to_string()).collect();
        let hidden_ids: std::collections::HashSet<Uuid> = self.cache
            .content_hidden_subset(&online_id_strs)
            .await
            .iter()
            .filter_map(|s| Uuid::parse_str(s).ok())
            .collect();

        let summaries: Vec<ConversationSummary> = rows
            .into_iter()
            .map(|row| conversation_row_to_summary(row, caller_id, &presence_map, &blocks, &hidden_ids))
            .collect();

        let barrier_is_stale = self.cache
            .get::<DateTime<Utc>>(&format!("chat:conv_list_barrier:{}", caller_id))
            .await
            .ok()
            .flatten()
            .map(|barrier| barrier > query_started_at)
            .unwrap_or(false);
        if !barrier_is_stale {
            let _ = self.cache.set(&cache_key, &summaries, CACHE_TTL_CONVERSATION_LIST).await;
        }
        Ok(summaries)
    }

    pub async fn list_conversations_cursor(
        &self,
        pools: &DbPools,
        caller_id: Uuid,
        view: ConversationView,
        cursor: Option<(DateTime<Utc>, Uuid)>,
        page_size: i64,
        exclude_left_groups: bool,
        kind: ConversationKind,
    ) -> Result<(Vec<ConversationSummary>, Option<String>), sqlx::Error> {
        let (status_filter, archived_filter): (Option<ParticipantStatus>, bool) = match view {
            ConversationView::Messages => (Some(ParticipantStatus::Accepted), false),
            ConversationView::Invitations => (Some(ParticipantStatus::Pending), false),
            ConversationView::Archives => (None, true),
        };

        let page_size = page_size.min(100);
        let cursor_ts = cursor.map(|(ts, _)| ts);
        let cursor_id = cursor.map(|(_, id)| id);

        let rows = sqlx::query_as::<_, ConversationListRow>(
            r#"
            SELECT
                me.conversation_id,
                other.participant_id      AS other_participant_id,
                other.participant_type    AS other_participant_type,
                u.username                 AS other_username,
                u.chat_name                AS other_chat_name,
                u.profile_image_url        AS other_profile_image_url,
                u.online_status_visibility AS other_online_status_visibility,
                u.last_seen_visibility     AS other_last_seen_visibility,
                u.last_seen_at             AS other_last_seen_at,
                COALESCE(EXISTS(
                    SELECT 1 FROM follows f
                    WHERE f.follower_id = $1 AND f.following_id = other.participant_id
                ), false) AS is_following,
                m.content_type            AS last_message_content_type,
                m.text_content            AS last_message_text,
                m.created_at              AS last_message_at,
                m.sender_id               AS last_message_sender_id,
                CASE WHEN m.content_type = 'bit' THEN EXISTS (
                    SELECT 1 FROM message_receipts mr
                    WHERE mr.message_id = m.id
                      AND mr.user_id != m.sender_id
                      AND mr.delivered_at IS NOT NULL
                ) ELSE (m.seq IS NOT NULL AND EXISTS (
                    SELECT 1 FROM conversation_participants rcp
                    WHERE rcp.conversation_id = m.conversation_id
                      AND rcp.participant_id != m.sender_id
                      AND rcp.last_delivered_seq >= m.seq
                )) END AS last_message_delivered,
                CASE WHEN m.content_type = 'bit' THEN EXISTS (
                    SELECT 1 FROM message_receipts mr
                    LEFT JOIN users rdr ON rdr.id = mr.user_id
                    LEFT JOIN users snd ON snd.id = m.sender_id
                    WHERE mr.message_id = m.id
                      AND mr.user_id != m.sender_id
                      AND mr.opened_at IS NOT NULL
                      AND (c.is_group OR (COALESCE(rdr.read_receipts_enabled, TRUE) AND COALESCE(snd.read_receipts_enabled, TRUE)))
                ) ELSE (m.seq IS NOT NULL AND EXISTS (
                    SELECT 1 FROM conversation_participants rcp
                    LEFT JOIN users rdr ON rdr.id = rcp.participant_id
                    LEFT JOIN users snd ON snd.id = m.sender_id
                    WHERE rcp.conversation_id = m.conversation_id
                      AND rcp.participant_id != m.sender_id
                      AND rcp.last_read_seq >= m.seq
                      AND (c.is_group OR (COALESCE(rdr.read_receipts_enabled, TRUE) AND COALESCE(snd.read_receipts_enabled, TRUE)))
                )) END AS last_message_opened,
                (
                    SELECT COUNT(*) FROM messages um
                    WHERE um.conversation_id = c.id
                      AND um.sender_id != $1
                      AND um.content_type != 'system'
                      AND um.deleted_at IS NULL
                      AND (me.last_read_message_id IS NULL OR um.created_at > (
                          SELECT created_at FROM messages WHERE id = me.last_read_message_id
                      ))
                      AND (me.left_at IS NULL OR um.created_at <= me.left_at)
                ) AS unread_count,
                me.status,
                other.status               AS other_status,
                me.archived,
                CASE WHEN me.muted_until IS NOT NULL AND me.muted_until <= now() THEN NULL ELSE me.muted_until END AS muted_until,
                c.is_group,
                c.group_name,
                c.group_image_url,
                c.e2ee_enabled
            FROM conversation_participants me
            JOIN conversations c ON c.id = me.conversation_id
            LEFT JOIN conversation_participants other
                ON other.conversation_id = me.conversation_id
               AND other.participant_id != me.participant_id
               AND c.is_group = false
            LEFT JOIN users u ON u.id = other.participant_id AND other.participant_type = 'user'
            LEFT JOIN LATERAL (
                SELECT lm.* FROM messages lm
                WHERE lm.conversation_id = c.id
                  AND lm.deleted_at IS NULL
                  AND (me.left_at IS NULL OR lm.created_at <= me.left_at)
                ORDER BY lm.created_at DESC, lm.id DESC
                LIMIT 1
            ) m ON true
            WHERE me.participant_id = $1
              AND me.deleted_at IS NULL
              AND me.archived = $2
              AND ($3::text IS NULL OR me.status = $3::text)
              AND c.last_message_id IS NOT NULL
              AND ($6 = false OR c.is_group = false OR me.left_at IS NULL)
              AND ($8::boolean IS NULL OR c.is_group = $8::boolean)
              AND (
                  $4::timestamptz IS NULL
                  OR ROW(COALESCE(m.created_at, '-infinity'::timestamptz), c.id)
                     < ROW($4::timestamptz, $5::uuid)
              )
            ORDER BY COALESCE(m.created_at, '-infinity'::timestamptz) DESC, c.id DESC
            LIMIT $7
            "#,
        )
        .bind(caller_id)
        .bind(archived_filter)
        .bind(status_filter.map(|s| match s { ParticipantStatus::Accepted => "accepted", ParticipantStatus::Pending => "pending" }))
        .bind(cursor_ts)
        .bind(cursor_id)
        .bind(exclude_left_groups)
        .bind(page_size)
        .bind(kind.is_group_filter())
        .fetch_all(pools.reader())
        .await?;

        let online_ids: Vec<Uuid> = rows.iter().filter_map(|r| r.other_participant_id).collect();
        let presence_map = self.bulk_presence(&online_ids).await;
        let blocks = self.block_lookup(pools, caller_id, &online_ids).await?;
        let online_id_strs: Vec<String> = online_ids.iter().map(|id| id.to_string()).collect();
        let hidden_ids: std::collections::HashSet<Uuid> = self.cache
            .content_hidden_subset(&online_id_strs)
            .await
            .iter()
            .filter_map(|s| Uuid::parse_str(s).ok())
            .collect();

        let next_cursor = if rows.len() == page_size as usize {
            rows.last().map(|last| {
                encode_conversation_cursor(
                    last.last_message_at.unwrap_or_else(|| DateTime::<Utc>::from_timestamp(0, 0).unwrap()),
                    last.conversation_id,
                )
            })
        } else {
            None
        };

        let summaries: Vec<ConversationSummary> = rows
            .into_iter()
            .map(|row| conversation_row_to_summary(row, caller_id, &presence_map, &blocks, &hidden_ids))
            .collect();

        Ok((summaries, next_cursor))
    }

    const CACHE_TTL_CHAT_SETTINGS: usize = 300;

    pub async fn get_chat_settings(&self, pools: &DbPools, user_id: Uuid) -> Result<ChatSettings, sqlx::Error> {
        let cache_key = format!("chat:settings:{}", user_id);
        if let Ok(Some(cached)) = self.cache.get::<ChatSettings>(&cache_key).await {
            return Ok(cached);
        }

        let settings = sqlx::query_as::<_, ChatSettings>(
            "SELECT chat_name, online_status_visibility, last_seen_visibility, read_receipts_enabled, \
                    chats_from_followers_only, group_invites_from_followers_only \
             FROM users WHERE id = $1",
        )
        .bind(user_id)
        .fetch_one(pools.reader())
        .await?;

        let _ = self.cache.set(&cache_key, &settings, Self::CACHE_TTL_CHAT_SETTINGS).await;
        Ok(settings)
    }

    pub async fn update_chat_settings(
        &self,
        pools: &DbPools,
        user_id: Uuid,
        req: UpdateChatSettingsRequest,
    ) -> Result<ChatSettings, sqlx::Error> {
        let chat_name_was_present = req.chat_name.is_some();
        let chat_name = req.chat_name.map(|n| {
            let trimmed = n.trim().to_string();
            if trimmed.is_empty() { None } else { Some(trimmed) }
        });

        let settings = sqlx::query_as::<_, ChatSettings>(
            r#"
            UPDATE users SET
                chat_name = CASE WHEN $2::boolean THEN $3::text ELSE chat_name END,
                online_status_visibility = COALESCE($4::text, online_status_visibility),
                last_seen_visibility = COALESCE($5::text, last_seen_visibility),
                read_receipts_enabled = COALESCE($6::boolean, read_receipts_enabled),
                chats_from_followers_only = COALESCE($7::boolean, chats_from_followers_only),
                group_invites_from_followers_only = COALESCE($8::boolean, group_invites_from_followers_only)
            WHERE id = $1
            RETURNING chat_name, online_status_visibility, last_seen_visibility, read_receipts_enabled,
                      chats_from_followers_only, group_invites_from_followers_only
            "#,
        )
        .bind(user_id)
        .bind(chat_name_was_present)
        .bind(chat_name)
        .bind(req.online_status_visibility.map(|v| match v {
            VisibilityLevel::Off => "off", VisibilityLevel::Public => "public", VisibilityLevel::Followers => "followers",
        }))
        .bind(req.last_seen_visibility.map(|v| match v {
            VisibilityLevel::Off => "off", VisibilityLevel::Public => "public", VisibilityLevel::Followers => "followers",
        }))
        .bind(req.read_receipts_enabled)
        .bind(req.chats_from_followers_only)
        .bind(req.group_invites_from_followers_only)
        .fetch_one(pools.writer())
        .await?;

        let cache_key = format!("chat:settings:{}", user_id);
        let _ = self.cache.set(&cache_key, &settings, Self::CACHE_TTL_CHAT_SETTINGS).await;
        if let Ok(partner_ids) = sqlx::query_scalar::<_, Uuid>(
            "SELECT DISTINCT other.participant_id
             FROM conversation_participants me
             JOIN conversation_participants other
               ON other.conversation_id = me.conversation_id AND other.participant_id != me.participant_id
             WHERE me.participant_id = $1",
        )
        .bind(user_id)
        .fetch_all(pools.reader())
        .await
        {
            self.invalidate_conversation_list_caches(&partner_ids).await;
        }
        self.invalidate_conversation_list_caches(&[user_id]).await;

        Ok(settings)
    }

    fn visible_presence(
        online_visibility: VisibilityLevel,
        last_seen_visibility: VisibilityLevel,
        viewer_is_follower: bool,
        is_online_now: bool,
        last_seen_at: Option<DateTime<Utc>>,
    ) -> PresenceInfo {
        let online = match online_visibility {
            VisibilityLevel::Off => None,
            VisibilityLevel::Public => Some(is_online_now),
            VisibilityLevel::Followers => viewer_is_follower.then_some(is_online_now),
        };
        let last_seen = match last_seen_visibility {
            VisibilityLevel::Off => None,
            VisibilityLevel::Public => last_seen_at,
            VisibilityLevel::Followers => viewer_is_follower.then_some(last_seen_at).flatten(),
        };
        PresenceInfo { online, last_seen }
    }

    pub async fn presence_for(&self, pools: &DbPools, viewer_id: Uuid, target_id: Uuid) -> Result<PresenceInfo, sqlx::Error> {
        if self.block_lookup(pools, viewer_id, &[target_id]).await?.blocked_either.contains(&target_id) {
            return Ok(PresenceInfo::default());
        }

        #[derive(sqlx::FromRow)]
        struct Row {
            online_status_visibility: VisibilityLevel,
            last_seen_visibility: VisibilityLevel,
            last_seen_at: Option<DateTime<Utc>>,
        }
        let row = sqlx::query_as::<_, Row>(
            "SELECT online_status_visibility, last_seen_visibility, last_seen_at FROM users WHERE id = $1",
        )
        .bind(target_id)
        .fetch_one(pools.reader())
        .await?;

        let is_follower: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM follows WHERE follower_id = $1 AND following_id = $2)",
        )
        .bind(viewer_id)
        .bind(target_id)
        .fetch_one(pools.reader())
        .await?;

        let presence_map = self.bulk_presence(&[target_id]).await;
        let entry = presence_map.get(&target_id);
        Ok(Self::visible_presence(
            row.online_status_visibility,
            row.last_seen_visibility,
            is_follower,
            entry.map(|e| e.online).unwrap_or(false),
            entry.map(|e| e.last_seen).or(row.last_seen_at),
        ))
    }

    async fn bulk_presence(&self, user_ids: &[Uuid]) -> std::collections::HashMap<Uuid, presence::PresenceEntry> {
        let checks = user_ids.iter().map(|id| {
            let id = *id;
            async move {
                let entry = presence::get_presence(&self.cache, id).await;
                (id, entry)
            }
        });
        futures_util::future::join_all(checks)
            .await
            .into_iter()
            .filter_map(|(id, entry)| entry.map(|e| (id, e)))
            .collect()
    }

    pub async fn presence_for_broadcast(
        &self,
        pools: &DbPools,
        user_id: Uuid,
        partner_ids: &[Uuid],
    ) -> Result<std::collections::HashMap<Uuid, PresenceInfo>, sqlx::Error> {
        if partner_ids.is_empty() {
            return Ok(std::collections::HashMap::new());
        }

        let blocked = self.block_lookup(pools, user_id, partner_ids).await?.blocked_either;

        #[derive(sqlx::FromRow)]
        struct Row {
            online_status_visibility: VisibilityLevel,
            last_seen_visibility: VisibilityLevel,
        }
        let row = sqlx::query_as::<_, Row>(
            "SELECT online_status_visibility, last_seen_visibility FROM users WHERE id = $1",
        )
        .bind(user_id)
        .fetch_one(pools.reader())
        .await?;

        let presence_map = self.bulk_presence(&[user_id]).await;
        let entry = presence_map.get(&user_id);
        let is_online_now = entry.map(|e| e.online).unwrap_or(false);
        let last_seen_at = entry.map(|e| e.last_seen);

        let needs_followers_check = matches!(row.online_status_visibility, VisibilityLevel::Followers)
            || matches!(row.last_seen_visibility, VisibilityLevel::Followers);

        let followers: std::collections::HashSet<Uuid> = if needs_followers_check {
            sqlx::query_scalar::<_, Uuid>(
                "SELECT follower_id FROM follows WHERE follower_id = ANY($1) AND following_id = $2",
            )
            .bind(partner_ids)
            .bind(user_id)
            .fetch_all(pools.reader())
            .await?
            .into_iter()
            .collect()
        } else {
            std::collections::HashSet::new()
        };

        let presence_for_follower = Self::visible_presence(
            row.online_status_visibility, row.last_seen_visibility, true, is_online_now, last_seen_at,
        );
        let presence_for_non_follower = Self::visible_presence(
            row.online_status_visibility, row.last_seen_visibility, false, is_online_now, last_seen_at,
        );

        Ok(partner_ids
            .iter()
            .filter(|partner_id| !blocked.contains(*partner_id))
            .map(|partner_id| {
                let presence = if followers.contains(partner_id) {
                    presence_for_follower.clone()
                } else {
                    presence_for_non_follower.clone()
                };
                (*partner_id, presence)
            })
            .collect())
    }

    pub async fn presence_for_viewer(
        &self,
        pools: &DbPools,
        viewer_id: Uuid,
        target_ids: &[Uuid],
    ) -> Result<std::collections::HashMap<Uuid, PresenceInfo>, sqlx::Error> {
        if target_ids.is_empty() {
            return Ok(std::collections::HashMap::new());
        }

        let blocked = self.block_lookup(pools, viewer_id, target_ids).await?.blocked_either;

        #[derive(sqlx::FromRow)]
        struct Row {
            id: Uuid,
            online_status_visibility: VisibilityLevel,
            last_seen_visibility: VisibilityLevel,
        }
        let rows = sqlx::query_as::<_, Row>(
            "SELECT id, online_status_visibility, last_seen_visibility FROM users WHERE id = ANY($1)",
        )
        .bind(target_ids)
        .fetch_all(pools.reader())
        .await?;

        let gated: Vec<Uuid> = rows
            .iter()
            .filter(|r| {
                matches!(r.online_status_visibility, VisibilityLevel::Followers)
                    || matches!(r.last_seen_visibility, VisibilityLevel::Followers)
            })
            .map(|r| r.id)
            .collect();
        let followed: std::collections::HashSet<Uuid> = if gated.is_empty() {
            std::collections::HashSet::new()
        } else {
            sqlx::query_scalar::<_, Uuid>(
                "SELECT following_id FROM follows WHERE follower_id = $1 AND following_id = ANY($2)",
            )
            .bind(viewer_id)
            .bind(&gated)
            .fetch_all(pools.reader())
            .await?
            .into_iter()
            .collect()
        };

        let presence_map = self.bulk_presence(target_ids).await;

        Ok(rows
            .into_iter()
            .filter(|r| !blocked.contains(&r.id))
            .map(|r| {
                let entry = presence_map.get(&r.id);
                let info = Self::visible_presence(
                    r.online_status_visibility,
                    r.last_seen_visibility,
                    followed.contains(&r.id),
                    entry.map(|e| e.online).unwrap_or(false),
                    entry.map(|e| e.last_seen),
                );
                (r.id, info)
            })
            .collect())
    }

    pub async fn delete_conversation_history(
        &self,
        pools: &DbPools,
        conversation_id: Uuid,
        caller_id: Uuid,
    ) -> Result<(), ChatError> {
        self.get_participant_row(pools, conversation_id, caller_id).await?;

        let mut tx = pools.writer().begin().await.map_err(ChatError::Db)?;

        sqlx::query(
            r#"
            INSERT INTO message_deletions (message_id, user_id)
            SELECT id, $2 FROM messages
            WHERE conversation_id = $1
            ON CONFLICT (message_id, user_id) DO NOTHING
            "#,
        )
        .bind(conversation_id)
        .bind(caller_id)
        .execute(&mut *tx)
        .await
        .map_err(ChatError::Db)?;

        sqlx::query(
            "UPDATE conversation_participants SET deleted_at = now() WHERE conversation_id = $1 AND participant_id = $2",
        )
        .bind(conversation_id)
        .bind(caller_id)
        .execute(&mut *tx)
        .await
        .map_err(ChatError::Db)?;

        tx.commit().await.map_err(ChatError::Db)?;

        self.invalidate_conversation_list_caches(&[caller_id]).await;
        Ok(())
    }

    pub async fn invalidate_conversation_list_caches(&self, participant_ids: &[Uuid]) {
    for id in participant_ids {
        let barrier_key = format!("chat:conv_list_barrier:{}", id);
        let _ = self.cache.set(&barrier_key, &Utc::now(), CACHE_BARRIER_TTL).await;
        for view in [ConversationView::Messages, ConversationView::Invitations, ConversationView::Archives] {
            for exclude_left_groups in [false, true] {
                for kind in [ConversationKind::All, ConversationKind::Direct, ConversationKind::Group] {
                    let key = format!("chat:conv_list:{}:{:?}:0:{}:{}:{:?}", id, view, 20, exclude_left_groups, kind);
                    let _ = self.cache.delete(&key).await;
                }
            }
        }
    }
}

    pub async fn get_participant_row(
        &self,
        pools: &DbPools,
        conversation_id: Uuid,
        caller_id: Uuid,
    ) -> Result<ConversationParticipant, ChatError> {
        sqlx::query_as::<_, ConversationParticipant>(
            "SELECT * FROM conversation_participants WHERE conversation_id = $1 AND participant_id = $2",
        )
        .bind(conversation_id)
        .bind(caller_id)
        .fetch_optional(pools.reader())
        .await?
        .ok_or(ChatError::NotParticipant)
    }

    pub async fn other_participant(
        &self,
        pools: &DbPools,
        conversation_id: Uuid,
        caller_id: Uuid,
    ) -> Result<Uuid, sqlx::Error> {
        self.other_participant_id(pools, conversation_id, caller_id).await
    }

    pub async fn get_call(&self, pools: &DbPools, call_id: Uuid) -> Result<Call, sqlx::Error> {
        match sqlx::query_as::<_, Call>("SELECT * FROM calls WHERE id = $1")
            .bind(call_id)
            .fetch_one(pools.reader())
            .await
        {
            Err(sqlx::Error::RowNotFound) => {
                sqlx::query_as::<_, Call>("SELECT * FROM calls WHERE id = $1")
                    .bind(call_id)
                    .fetch_one(pools.writer())
                    .await
            }
            other => other,
        }
    }

    async fn other_participant_id(
        &self,
        pools: &DbPools,
        conversation_id: Uuid,
        caller_id: Uuid,
    ) -> Result<Uuid, sqlx::Error> {
        sqlx::query_scalar(
            "SELECT participant_id FROM conversation_participants WHERE conversation_id = $1 AND participant_id != $2 LIMIT 1",
        )
        .bind(conversation_id)
        .bind(caller_id)
        .fetch_one(pools.reader())
        .await
    }

    pub async fn active_participant_ids(
        &self,
        pools: &DbPools,
        conversation_id: Uuid,
        exclude: Uuid,
    ) -> Result<Vec<Uuid>, sqlx::Error> {
        let cache_key = Self::active_participants_cache_key(conversation_id);
        if let Ok(Some(cached)) = self.cache.get::<Vec<Uuid>>(&cache_key).await {
            return Ok(cached.into_iter().filter(|id| *id != exclude).collect());
        }

        let ids: Vec<Uuid> = sqlx::query_scalar(
            r#"
            SELECT participant_id FROM conversation_participants
            WHERE conversation_id = $1
              AND status = 'accepted' AND left_at IS NULL
            "#,
        )
        .bind(conversation_id)
        .fetch_all(pools.reader())
        .await?;

        let _ = self.cache.set(&cache_key, &ids, CACHE_TTL_ACTIVE_PARTICIPANTS).await;

        Ok(ids.into_iter().filter(|id| id != &exclude).collect())
    }

    pub async fn live_share_recipients(
        &self,
        pools: &DbPools,
        conversation_id: Uuid,
        sender_id: Uuid,
    ) -> Result<Vec<Uuid>, sqlx::Error> {
        let all = self.active_participant_ids(pools, conversation_id, Uuid::nil()).await?;
        if !all.contains(&sender_id) {
            return Ok(Vec::new());
        }
        Ok(all.into_iter().filter(|id| *id != sender_id).collect())
    }

    pub async fn typing_recipient_ids(
        &self,
        pools: &DbPools,
        conversation_id: Uuid,
        exclude: Uuid,
    ) -> Result<Vec<Uuid>, sqlx::Error> {
        let cache_key = Self::typing_recipients_cache_key(conversation_id);
        if let Ok(Some(cached)) = self.cache.get::<Vec<Uuid>>(&cache_key).await {
            return Ok(cached.into_iter().filter(|id| *id != exclude).collect());
        }

        let ids: Vec<Uuid> = sqlx::query_scalar(
            r#"
            SELECT participant_id FROM conversation_participants
            WHERE conversation_id = $1
              AND status = 'accepted' AND left_at IS NULL
              AND archived = FALSE
            "#,
        )
        .bind(conversation_id)
        .fetch_all(pools.reader())
        .await?;

        let _ = self.cache.set(&cache_key, &ids, CACHE_TTL_ACTIVE_PARTICIPANTS).await;
        Ok(ids.into_iter().filter(|id| id != &exclude).collect())
    }

    fn typing_recipients_cache_key(conversation_id: Uuid) -> String {
        format!("chat:typing_recipients:{}", conversation_id)
    }

    fn active_participants_cache_key(conversation_id: Uuid) -> String {
        format!("chat:active_participants:{}", conversation_id)
    }

    async fn invalidate_active_participants_cache(&self, conversation_id: Uuid) {
        let _ = self.cache.delete(&Self::active_participants_cache_key(conversation_id)).await;
        let _ = self.cache.delete(&Self::typing_recipients_cache_key(conversation_id)).await;
    }

    pub async fn get_messages(
        &self,
        pools: &DbPools,
        conversation_id: Uuid,
        caller_id: Uuid,
        before: Option<Uuid>,
        limit: i64,
    ) -> Result<Vec<MessageWithReceipt>, ChatError> {
        let caller_row = self.get_participant_row(pools, conversation_id, caller_id).await?;
        let left_at_cutoff = caller_row.left_at;

        let limit = limit.clamp(1, MAX_MESSAGE_PAGE_SIZE);

        let mut messages = if let Some(before_id) = before {
    let cursor = sqlx::query_as::<_, (chrono::DateTime<chrono::Utc>, Uuid)>(
        "SELECT created_at, id FROM messages WHERE id = $1",
    )
    .bind(before_id)
    .fetch_optional(pools.reader())
    .await?
    .ok_or(ChatError::Db(sqlx::Error::RowNotFound))?;

    sqlx::query_as::<_, Message>(
        r#"
        SELECT * FROM messages
        WHERE conversation_id = $1
          AND (deleted_at IS NULL OR NOT is_disappearing)
          AND (created_at, id) < ($3, $4)
          AND NOT EXISTS (SELECT 1 FROM message_deletions md WHERE md.message_id = messages.id AND md.user_id = $5)
          AND ($6::timestamptz IS NULL OR created_at <= $6::timestamptz)
        ORDER BY created_at DESC, id DESC
        LIMIT $2
        "#,
    )
    .bind(conversation_id)
    .bind(limit)
    .bind(cursor.0)
    .bind(cursor.1)
    .bind(caller_id)
    .bind(left_at_cutoff)
    .fetch_all(pools.reader())
    .await?
} else {
            sqlx::query_as::<_, Message>(
                r#"
                SELECT * FROM messages
                WHERE conversation_id = $1
                  AND (deleted_at IS NULL OR NOT is_disappearing)
                  AND NOT EXISTS (SELECT 1 FROM message_deletions md WHERE md.message_id = messages.id AND md.user_id = $3)
                  AND ($4::timestamptz IS NULL OR created_at <= $4::timestamptz)
                ORDER BY created_at DESC LIMIT $2
                "#,
            )
            .bind(conversation_id)
            .bind(limit)
            .bind(caller_id)
            .bind(left_at_cutoff)
            .fetch_all(pools.reader())
            .await?
        };

        messages.reverse();

        if messages.is_empty() {
            return Ok(Vec::new());
        }

        let message_ids: Vec<Uuid> = messages.iter().map(|m| m.id).collect();
        #[derive(sqlx::FromRow)]
        struct ReceiptRow {
            message_id: Uuid,
            delivered: bool,
            opened: bool,
            opened_at: Option<chrono::DateTime<chrono::Utc>>,
        }
        let receipts: Vec<ReceiptRow> = sqlx::query_as(
            r#"
            SELECT
                m.id AS message_id,
                COALESCE(agg.delivered, FALSE) AS delivered,
                COALESCE(agg.opened, FALSE)    AS opened,
                agg.opened_at                  AS opened_at
            FROM messages m
            JOIN conversations c ON c.id = m.conversation_id
            LEFT JOIN users sender ON sender.id = m.sender_id
            LEFT JOIN LATERAL (
                SELECT
                    BOOL_OR(x.delivered) AS delivered,
                    BOOL_OR(x.opened AND (c.is_group OR (COALESCE(reader.read_receipts_enabled, TRUE) AND COALESCE(sender.read_receipts_enabled, TRUE)))) AS opened,
                    MIN(x.opened_at) FILTER (WHERE x.opened AND (c.is_group OR (COALESCE(reader.read_receipts_enabled, TRUE) AND COALESCE(sender.read_receipts_enabled, TRUE)))) AS opened_at
                FROM (
                    SELECT r.user_id,
                           (r.delivered_at IS NOT NULL OR r.opened_at IS NOT NULL) AS delivered,
                           (r.opened_at IS NOT NULL) AS opened,
                           r.opened_at AS opened_at
                    FROM message_receipts r
                    WHERE m.content_type = 'bit'
                      AND r.message_id = m.id
                      AND r.user_id != m.sender_id
                    UNION ALL
                    SELECT rcp.participant_id,
                           (rcp.last_delivered_seq >= m.seq),
                           (rcp.last_read_seq >= m.seq),
                           CASE WHEN rcp.last_read_seq >= m.seq THEN rcp.last_read_at END
                    FROM conversation_participants rcp
                    WHERE m.content_type <> 'bit'
                      AND m.seq IS NOT NULL
                      AND rcp.conversation_id = m.conversation_id
                      AND rcp.participant_id != m.sender_id
                ) x
                LEFT JOIN users reader ON reader.id = x.user_id
            ) agg ON TRUE
            WHERE m.id = ANY($1)
            "#,
        )
        .bind(&message_ids)
        .fetch_all(pools.reader())
        .await?;
        let receipt_map: std::collections::HashMap<Uuid, (bool, bool, Option<chrono::DateTime<chrono::Utc>>)> = receipts
            .into_iter()
            .map(|r| (r.message_id, (r.delivered, r.opened, r.opened_at)))
            .collect();

        let all_reactions: Vec<MessageReaction> = sqlx::query_as(
            "SELECT * FROM message_reactions WHERE message_id = ANY($1) ORDER BY created_at",
        )
        .bind(&message_ids)
        .fetch_all(pools.reader())
        .await?;
        let mut reaction_map: std::collections::HashMap<Uuid, Vec<MessageReaction>> = std::collections::HashMap::new();
        for reaction in all_reactions {
            reaction_map.entry(reaction.message_id).or_default().push(reaction);
        }

        let e2ee_ids: Vec<Uuid> = messages.iter().filter(|m| m.e2ee_envelope.is_some()).map(|m| m.id).collect();
        let mut e2ee_cts = e2ee::ciphertexts_for_user(pools, &e2ee_ids, caller_id).await?;

        Ok(messages
            .into_iter()
            .map(|mut message| {
                if message.e2ee_envelope.is_some() {
                    message.e2ee_ciphertexts = Some(e2ee_cts.remove(&message.id).unwrap_or_default());
                }
                let (delivered, opened, opened_at) = receipt_map.get(&message.id).cloned().unwrap_or((false, false, None));
                let reactions = reaction_map.remove(&message.id).unwrap_or_default();
                MessageWithReceipt { message, delivered, opened, opened_at, reactions }
            })
            .collect())
    }

    pub async fn send_message(
        &self,
        pools: &DbPools,
        conversation_id: Uuid,
        sender_id: Uuid,
        sender_type: ParticipantType,
        req: SendMessageRequest,
        client_temp_id: Option<String>,
    ) -> Result<Message, ChatError> {
        let sender_row = self.get_participant_row(pools, conversation_id, sender_id).await?;
        let empty_thread_claim = self
            .claim_empty_direct_thread(pools, conversation_id, sender_id, sender_type)
            .await?;
        if empty_thread_claim.is_none() && sender_row.status != ParticipantStatus::Accepted {
            return Err(ChatError::RequestNotAccepted);
        }
        if sender_row.left_at.is_some() {
            return Err(ChatError::LeftConversation);
        }

        let convo_is_group: bool = sqlx::query_scalar("SELECT is_group FROM conversations WHERE id = $1")
            .bind(conversation_id)
            .fetch_optional(pools.reader())
            .await?
            .unwrap_or(false);
        if !convo_is_group {
            let other: Option<(Uuid, ParticipantType)> = sqlx::query_as(
                "SELECT participant_id, participant_type FROM conversation_participants \
                 WHERE conversation_id = $1 AND participant_id != $2"
            )
            .bind(conversation_id)
            .bind(sender_id)
            .fetch_optional(pools.reader())
            .await?;
            if let Some((other_id, other_type)) = other {
                self.ensure_recipient_active(other_id, other_type).await?;
            }
        }

        let (is_group, group_deleted, group_name): (bool, bool, Option<String>) = sqlx::query_as(
            "SELECT is_group, group_deleted_at IS NOT NULL, group_name FROM conversations WHERE id = $1",
        )
        .bind(conversation_id)
        .fetch_one(pools.reader())
        .await?;
        if group_deleted {
            return Err(ChatError::GroupDeleted);
        }

        let plaintext_ok = e2ee::plaintext_allowed_for_unsupported() && !is_encryptable_request(&req);
        let (e2ee_fanout, newly_e2ee): (Option<std::collections::HashMap<Uuid, Uuid>>, bool) =
            e2ee::gate_and_validate(pools, conversation_id, sender_id, req.e2ee.as_ref(), plaintext_ok, true).await?;
        if newly_e2ee {
            self.broadcast_e2ee_enabled(pools, conversation_id, sender_id).await;
        }
        let e2ee_payload: Option<&E2eeSendPayload> = req.e2ee.as_ref();
        if let (Some(p), Some(_)) = (e2ee_payload, e2ee_fanout.as_ref()) {
            if req.content_type == MessageContentType::System
                || req.text_content.is_some()
                || req.media_url.is_some()
                || !req.media_metadata.as_ref().map_or(true, e2ee_public_meta_ok)
            {
                return Err(e2ee::E2eeError::Invalid(
                    "encrypted messages carry no plaintext content or media metadata".into(),
                )
                .into());
            }
            if let Some(existing) =
                e2ee::find_by_client_msg_id(pools, conversation_id, sender_id, p.client_msg_id).await?
            {
                return Ok(existing);
            }
        }
        let is_e2ee = e2ee_fanout.is_some();
        let e2ee_envelope_json: Option<serde_json::Value> = e2ee_payload.map(e2ee::envelope_json);
        let e2ee_per_user: Option<std::collections::HashMap<Uuid, Vec<CiphertextOut>>> = match (e2ee_payload, e2ee_fanout.as_ref()) {
            (Some(p), Some(f)) => Some(e2ee::ciphertexts_by_user(p, f)),
            _ => None,
        };

        let other_ids: Vec<Uuid> = if is_group {
            sqlx::query_scalar(
                r#"
                SELECT participant_id FROM conversation_participants
                WHERE conversation_id = $1 AND participant_id != $2
                  AND status = 'accepted' AND left_at IS NULL
                "#,
            )
            .bind(conversation_id)
            .bind(sender_id)
            .fetch_all(pools.reader())
            .await?
        } else {
            vec![self.other_participant_id(pools, conversation_id, sender_id).await?]
        };

        if !is_group {
            if !self.can_message(pools, sender_id, other_ids[0]).await? {
                return Err(ChatError::Blocked);
            }
        }

        let had_prior_message: bool = sqlx::query_scalar::<_, Option<Uuid>>(
            "SELECT last_message_id FROM conversations WHERE id = $1",
        )
        .bind(conversation_id)
        .fetch_one(pools.reader())
        .await?
        .is_some();

        let other_participant_row = if is_group { None } else {
            self.get_participant_row(pools, conversation_id, other_ids[0]).await.ok()
        };
        let other_is_pending = match empty_thread_claim {
            Some((_, other_status)) => other_status == ParticipantStatus::Pending,
            None => other_participant_row
                .as_ref()
                .map(|r| r.status == ParticipantStatus::Pending)
                .unwrap_or(false),
        };
        let other_was_hidden = other_participant_row
            .as_ref()
            .map(|r| r.deleted_at.is_some())
            .unwrap_or(false);
        let other_row_id = other_participant_row.as_ref().map(|r| r.id);

        if other_is_pending
            && matches!(sender_type, ParticipantType::User)
            && other_participant_row
                .as_ref()
                .map(|r| matches!(r.participant_type, ParticipantType::User))
                .unwrap_or(false)
        {
            self.ensure_sender_follows_for_dm(pools, sender_id, other_ids[0]).await?;
        }
        let is_new_or_reopened_request = other_is_pending && (other_was_hidden || !had_prior_message);

        let is_bit = req.content_type == MessageContentType::Bit;
        let is_disappearing = is_bit || req.is_disappearing.unwrap_or(false);
        let is_live_location_share = req.content_type == MessageContentType::Location
            && req.media_metadata.as_ref().and_then(|m| m.is_live_location).unwrap_or(false);
        let expires_at: Option<DateTime<Utc>> = if is_bit {
            Some(Utc::now() + BIT_UNOPENED_TTL)
        } else if is_live_location_share {
            Some(Utc::now() + LIVE_LOCATION_SAFETY_TTL)
        } else {
            None
        };

        let media_metadata_json = req.media_metadata.as_ref().map(|m| serde_json::to_value(m).unwrap_or(serde_json::json!({})));

        let mut tx = pools.writer().begin().await?;

        let seq: i64 = sqlx::query_scalar(
            "UPDATE conversations SET last_seq = last_seq + 1 WHERE id = $1 RETURNING last_seq",
        )
        .bind(conversation_id)
        .fetch_one(&mut *tx)
        .await?;

        let message = sqlx::query_as::<_, Message>(
            r#"
            INSERT INTO messages (
                conversation_id, sender_id, sender_type, content_type,
                text_content, media_url, media_metadata, reply_to_message_id,
                is_disappearing, expires_at, seq, e2ee_envelope
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
            RETURNING *
            "#,
        )
        .bind(conversation_id)
        .bind(sender_id)
        .bind(sender_type)
        .bind(req.content_type)
        .bind(&req.text_content)
        .bind(&req.media_url)
        .bind(media_metadata_json)
        .bind(req.reply_to_message_id)
        .bind(is_disappearing)
        .bind(expires_at)
        .bind(seq)
        .bind(&e2ee_envelope_json)
        .fetch_one(&mut *tx)
        .await?;

        if let (Some(p), Some(f)) = (e2ee_payload, e2ee_fanout.as_ref()) {
            e2ee::store_ciphertexts(&mut tx, message.id, p, f, false).await?;
        }

        if is_bit {
            sqlx::query(
                "INSERT INTO message_receipts (message_id, user_id) SELECT $1, UNNEST($2::uuid[])",
            )
            .bind(message.id)
            .bind(&other_ids)
            .execute(&mut *tx)
            .await?;
        }

        sqlx::query(
            "UPDATE conversations SET last_message_id = $2, last_message_at = $3 WHERE id = $1",
        )
        .bind(conversation_id)
        .bind(message.id)
        .bind(message.created_at)
        .execute(&mut *tx)
        .await?;

        if other_was_hidden {
            if let Some(row_id) = other_row_id {
                sqlx::query(
                    "UPDATE conversation_participants SET deleted_at = NULL WHERE id = $1",
                )
                .bind(row_id)
                .execute(&mut *tx)
                .await?;
            }
        }

        tx.commit().await?;

        let mut caches_to_invalidate = other_ids.clone();
        caches_to_invalidate.push(sender_id);
        self.invalidate_conversation_list_caches(&caches_to_invalidate).await;

        #[derive(sqlx::FromRow)]
        struct MuteRow {
            participant_id: Uuid,
            muted_until: Option<DateTime<Utc>>,
            notifications_enabled: bool,
        }
        let muted_recipient_ids: std::collections::HashSet<Uuid> = sqlx::query_as::<_, MuteRow>(
            r#"SELECT participant_id, muted_until, notifications_enabled
               FROM conversation_participants
               WHERE conversation_id = $1 AND participant_id = ANY($2)"#,
        )
        .bind(conversation_id)
        .bind(&other_ids)
        .fetch_all(pools.reader())
        .await
        .unwrap_or_default()
        .into_iter()
        .filter(|r| {
            let currently_muted = r.muted_until.map(|until| until > Utc::now()).unwrap_or(false);
            currently_muted || !r.notifications_enabled
        })
        .map(|r| r.participant_id)
        .collect();

        let mut push_events: std::collections::HashMap<Uuid, notif_shared::NotificationEvent> =
            std::collections::HashMap::new();
        for recipient_id in &other_ids {
            let recipient_id = *recipient_id;
            if muted_recipient_ids.contains(&recipient_id) {
                continue;
            }
            if other_is_pending && !is_group {
                if is_new_or_reopened_request {
                    push_events.insert(
                        recipient_id,
                        notif_shared::NotificationEvent::MessageRequested {
                            actor_id: sender_id, recipient_id, conversation_id,
                        },
                    );
                }
                continue;
            }
            let event = if is_bit {
                notif_shared::NotificationEvent::BitReceived {
                    actor_id: sender_id, recipient_id, conversation_id, bit_id: message.id,
                }
            } else {
                let preview = match req.content_type {
                    MessageContentType::Image => "sent a photo".to_string(),
                    MessageContentType::Video => "sent a video".to_string(),
                    MessageContentType::Voice => "sent a voice message".to_string(),
                    MessageContentType::Location => "shared a location".to_string(),
                    MessageContentType::File => "sent a file".to_string(),
                    _ if is_e2ee => "New message".to_string(),
                    _ => req.text_content.clone().unwrap_or_default(),
                };
                notif_shared::NotificationEvent::MessageSent {
                    actor_id: sender_id, recipient_id, conversation_id,
                    message_id: message.id, preview,
                    group_name: group_name.clone(),
                }
            };
            push_events.insert(recipient_id, event);
        }

        let gateway_guard = unacked_push_in_gateway();
        let mut reached_recipients: std::collections::HashSet<Uuid> = std::collections::HashSet::new();
        for recipient_id in &other_ids {
            if other_is_pending && !is_group && !is_new_or_reopened_request {
                continue;
            }
            let event_id = append_inbox(&self.cache, *recipient_id, conversation_id, message.id, seq).await;
            let mut frame = serde_json::json!({
                "type": "new_message",
                "conversation_id": conversation_id,
                "seq": seq,
                "message": message_for_user(&message, e2ee_per_user.as_ref(), *recipient_id),
            });
            if let Some(id) = event_id {
                frame["event_id"] = serde_json::Value::String(id);
            }
            if gateway_guard {
                if let Some(ev) = push_events.get(recipient_id) {
                    if let Ok(v) = serde_json::to_value(ev) {
                        frame["_guard"] = v;
                    }
                }
            }
            let Ok(payload) = serde_json::to_string(&frame) else { continue };
            match self.cache.publish_user_event(&recipient_id.to_string(), &payload).await {
                Ok(subscribers) => {
                    if (subscribers as i64) > 0 {
                        reached_recipients.insert(*recipient_id);
                    }
                }
                Err(e) => {
                    log::error!("send_message: failed to notify recipient {} of message {}: {}", recipient_id, message.id, e);
                }
            }
        }

        {
            let ack_event = serde_json::json!({
                "type": "message_ack",
                "client_temp_id": client_temp_id.unwrap_or_default(),
                "seq": seq,
                "message": message_for_user(&message, e2ee_per_user.as_ref(), sender_id),
            });
            if let Ok(payload) = serde_json::to_string(&ack_event) {
                if let Err(e) = self.cache.publish_user_event(&sender_id.to_string(), &payload).await {
                    log::error!("send_message: failed to echo message {} to sender {}: {}", message.id, sender_id, e);
                }
            }
        }

        let mut awaiting_ack: Vec<(Uuid, notif_shared::NotificationEvent)> = Vec::new();
        for recipient_id in other_ids {
            let Some(event) = push_events.remove(&recipient_id) else { continue };
            let looks_live = reached_recipients.contains(&recipient_id)
                && presence::is_online(&self.cache, recipient_id).await;
            if looks_live {
                if !gateway_guard {
                    awaiting_ack.push((recipient_id, event));
                }
                continue;
            }
            let cache_clone = self.cache.clone();
            actix_web::rt::spawn(async move {
                if let Err(e) = notif_shared::publish_event(&cache_clone, &event).await {
                    log::error!("send_message: failed to publish notification event: {}", e);
                }
            });
        }

        schedule_unacked_push_guards(self.cache.clone(), message.id, awaiting_ack);

        Ok(message)
    }

    pub async fn replay_inbox(&self, pools: &DbPools, user_id: Uuid, after_event_id: &str) -> Vec<String> {
        let valid = !after_event_id.is_empty()
            && after_event_id.len() <= 40
            && after_event_id.chars().all(|c| c.is_ascii_digit() || c == '-')
            && after_event_id.matches('-').count() <= 1;
        if !valid {
            return Vec::new();
        }

        let mut conn = self.cache.client.clone();
        let reply: redis::streams::StreamRangeReply = match redis::cmd("XRANGE")
            .arg(inbox_key(user_id))
            .arg(format!("({}", after_event_id))
            .arg("+")
            .arg("COUNT")
            .arg(INBOX_REPLAY_LIMIT)
            .query_async(&mut conn)
            .await
        {
            Ok(r) => r,
            Err(_) => return Vec::new(),
        };

        struct Entry { event_id: String, conversation_id: Uuid, message_id: Uuid, seq: i64 }
        let mut entries: Vec<Entry> = Vec::new();
        for e in reply.ids {
            let (Some(c), Some(m)) = (e.get::<String>("c"), e.get::<String>("m")) else { continue };
            let (Ok(conversation_id), Ok(message_id)) = (Uuid::parse_str(&c), Uuid::parse_str(&m)) else { continue };
            let seq = e.get::<String>("s").and_then(|s| s.parse::<i64>().ok()).unwrap_or(0);
            entries.push(Entry { event_id: e.id, conversation_id, message_id, seq });
        }
        if entries.is_empty() {
            return Vec::new();
        }

        let ids: Vec<Uuid> = entries.iter().map(|e| e.message_id).collect();
        let rows = sqlx::query_as::<_, Message>(
            r#"SELECT * FROM messages
               WHERE id = ANY($1)
                 AND deleted_at IS NULL
                 AND (expires_at IS NULL OR expires_at > now())"#,
        )
        .bind(&ids)
        .fetch_all(pools.reader())
        .await
        .unwrap_or_default();
        let mut by_id: std::collections::HashMap<Uuid, Message> =
            rows.into_iter().map(|m| (m.id, m)).collect();

        let e2ee_ids: Vec<Uuid> = by_id.values().filter(|m| m.e2ee_envelope.is_some()).map(|m| m.id).collect();
        let mut e2ee_cts = e2ee::ciphertexts_for_user(pools, &e2ee_ids, user_id).await.unwrap_or_default();

        let mut frames = Vec::with_capacity(entries.len());
        for e in entries {
            let Some(mut message) = by_id.remove(&e.message_id) else { continue };
            if message.e2ee_envelope.is_some() {
                message.e2ee_ciphertexts = Some(e2ee_cts.remove(&message.id).unwrap_or_default());
            }
            let frame = serde_json::json!({
                "type": "new_message",
                "conversation_id": e.conversation_id,
                "seq": e.seq,
                "event_id": e.event_id,
                "message": message,
            });
            if let Ok(f) = serde_json::to_string(&frame) {
                frames.push(f);
            }
        }
        frames
    }

    pub async fn mark_delivered(&self, pools: &DbPools, message_id: Uuid, user_id: Uuid) -> Result<(), sqlx::Error> {
        let original_sender_id: Option<Uuid> = sqlx::query_scalar(
            r#"
            WITH target AS (
                SELECT m.id, m.sender_id, m.seq, m.content_type, m.conversation_id
                FROM messages m
                JOIN conversation_participants cp
                    ON cp.conversation_id = m.conversation_id
                   AND cp.participant_id = $2
                WHERE m.id = $1
                  AND m.sender_id != $2
                  AND m.content_type <> 'system'
                  AND cp.status = 'accepted'
                  AND cp.left_at IS NULL
            ),
            bit_receipt AS (
                UPDATE message_receipts r
                SET delivered_at = COALESCE(r.delivered_at, NOW())
                FROM target t
                WHERE t.content_type = 'bit'
                  AND r.message_id = t.id
                  AND r.user_id = $2
                RETURNING 1
            ),
            cur AS (
                UPDATE conversation_participants cp
                SET last_delivered_seq = t.seq,
                    last_delivered_at  = NOW()
                FROM target t
                WHERE t.content_type <> 'bit'
                  AND t.seq IS NOT NULL
                  AND cp.conversation_id = t.conversation_id
                  AND cp.participant_id = $2
                  AND cp.last_delivered_seq < t.seq
                RETURNING 1
            )
            SELECT sender_id FROM target
            "#,
        )
        .bind(message_id)
        .bind(user_id)
        .fetch_optional(pools.writer())
        .await?;

        if let Some(original_sender_id) = original_sender_id {
            self.invalidate_conversation_list_caches(&[original_sender_id]).await;
            let event = serde_json::json!({
                "type": "delivered",
                "message_id": message_id,
                "user_id": user_id,
            });
            if let Ok(payload) = serde_json::to_string(&event) {
                if let Err(e) = self.cache.publish_user_event(&original_sender_id.to_string(), &payload).await {
                    log::error!("mark_delivered: failed to notify sender {} for message {}: {}", original_sender_id, message_id, e);
                }
            }
        }
        Ok(())
    }

    async fn require_accepted_participant_for_message(
        &self,
        pools: &DbPools,
        message_id: Uuid,
        caller_id: Uuid,
    ) -> Result<Uuid, ChatError> {
        let conversation_id: Uuid = sqlx::query_scalar(
            "SELECT conversation_id FROM messages WHERE id = $1 AND deleted_at IS NULL",
        )
        .bind(message_id)
        .fetch_optional(pools.reader())
        .await?
        .ok_or(ChatError::NotFound)?;

        let caller_row = self.get_participant_row(pools, conversation_id, caller_id).await?;
        if caller_row.status != ParticipantStatus::Accepted {
            return Err(ChatError::RequestNotAccepted);
        }
        Ok(conversation_id)
    }

    async fn broadcast_reaction_update(
        &self,
        pools: &DbPools,
        conversation_id: Uuid,
        message_id: Uuid,
        actor_id: Uuid,
        reactions: &[MessageReaction],
    ) {
        let event = serde_json::json!({
            "type": "reaction_updated",
            "conversation_id": conversation_id,
            "message_id": message_id,
            "reactions": reactions,
        });
        let payload = match serde_json::to_string(&event) {
            Ok(p) => p,
            Err(e) => {
                log::error!("broadcast_reaction_update: failed to serialize event for message {}: {}", message_id, e);
                return;
            }
        };

        let mut recipients: Vec<Uuid> = sqlx::query_scalar(
            r#"
            SELECT participant_id FROM conversation_participants
            WHERE conversation_id = $1 AND participant_id != $2
              AND status = 'accepted' AND left_at IS NULL
            "#,
        )
        .bind(conversation_id)
        .bind(actor_id)
        .fetch_all(pools.reader())
        .await
        .unwrap_or_else(|e| {
            log::error!("broadcast_reaction_update: failed to list participants for {}: {}", conversation_id, e);
            Vec::new()
        });
        recipients.push(actor_id);

        for recipient_id in recipients {
            if let Err(e) = self.cache.publish_user_event(&recipient_id.to_string(), &payload).await {
                log::error!("broadcast_reaction_update: failed to notify {} for message {}: {}", recipient_id, message_id, e);
            }
        }
    }

    pub async fn add_reaction(
        &self,
        pools: &DbPools,
        message_id: Uuid,
        user_id: Uuid,
        emoji: String,
    ) -> Result<MessageReaction, ChatError> {
        let conversation_id = self.require_accepted_participant_for_message(pools, message_id, user_id).await?;

        let reaction: MessageReaction = sqlx::query_as(
            r#"
            INSERT INTO message_reactions (id, message_id, user_id, emoji)
            VALUES (gen_random_uuid(), $1, $2, $3)
            ON CONFLICT (message_id, user_id, emoji) DO UPDATE SET emoji = EXCLUDED.emoji
            RETURNING *
            "#,
        )
        .bind(message_id)
        .bind(user_id)
        .bind(&emoji)
        .fetch_one(pools.writer())
        .await?;

        let all_reactions: Vec<MessageReaction> = sqlx::query_as(
            "SELECT * FROM message_reactions WHERE message_id = $1 ORDER BY created_at",
        )
        .bind(message_id)
        .fetch_all(pools.writer())  
        .await?;

        self.broadcast_reaction_update(pools, conversation_id, message_id, user_id, &all_reactions).await;

        self.notify_reaction_if_offline(pools, message_id, conversation_id, user_id, &emoji).await;

        Ok(reaction)
    }

    async fn notify_reaction_if_offline(
        &self,
        pools: &DbPools,
        message_id: Uuid,
        conversation_id: Uuid,
        actor_id: Uuid,
        emoji: &str,
    ) {
        let Ok(Some((sender_id, content_type, text_content, is_disappearing))) = sqlx::query_as::<
            _,
            (Uuid, MessageContentType, Option<String>, bool),
        >("SELECT sender_id, content_type, text_content, is_disappearing FROM messages WHERE id = $1")
            .bind(message_id)
            .fetch_optional(pools.reader())
            .await
        else {
            return;
        };

        if sender_id == actor_id {
            return;
        }

        if presence::is_online(&self.cache, sender_id).await {
            return;
        }

        let group_name: Option<String> = sqlx::query_scalar(
            "SELECT group_name FROM conversations WHERE id = $1",
        )
        .bind(conversation_id)
        .fetch_optional(pools.reader())
        .await
        .ok()
        .flatten();

        let preview = if content_type == MessageContentType::Bit || is_disappearing {
            "your message".to_string()
        } else {
            match content_type {
                MessageContentType::Image => "a photo".to_string(),
                MessageContentType::Video => "a video".to_string(),
                MessageContentType::Voice => "a voice message".to_string(),
                MessageContentType::Location => "a location".to_string(),
                MessageContentType::File => "a file".to_string(),
                _ => text_content.unwrap_or_else(|| "your message".to_string()),
            }
        };

        let event = notif_shared::NotificationEvent::MessageReacted {
            actor_id,
            recipient_id: sender_id,
            conversation_id,
            message_id,
            emoji: emoji.to_string(),
            preview,
            group_name,
        };
        let cache_clone = self.cache.clone();
        actix_web::rt::spawn(async move {
            if let Err(e) = notif_shared::publish_event(&cache_clone, &event).await {
                log::error!("add_reaction: failed to publish notification event: {}", e);
            }
        });
    }

    pub async fn remove_reaction(
        &self,
        pools: &DbPools,
        message_id: Uuid,
        user_id: Uuid,
        emoji: String,
    ) -> Result<(), ChatError> {
        let conversation_id = self.require_accepted_participant_for_message(pools, message_id, user_id).await?;

        sqlx::query("DELETE FROM message_reactions WHERE message_id = $1 AND user_id = $2 AND emoji = $3")
            .bind(message_id)
            .bind(user_id)
            .bind(&emoji)
            .execute(pools.writer())
            .await?;

        let all_reactions: Vec<MessageReaction> = sqlx::query_as(
            "SELECT * FROM message_reactions WHERE message_id = $1 ORDER BY created_at",
        )
        .bind(message_id)
        .fetch_all(pools.writer())
        .await?;

        self.broadcast_reaction_update(pools, conversation_id, message_id, user_id, &all_reactions).await;

        Ok(())
    }

    async fn broadcast_message_deleted(
        &self,
        pools: &DbPools,
        conversation_id: Uuid,
        message_id: Uuid,
        actor_id: Uuid,
        deleted_at: DateTime<Utc>,
    ) {
        let event = serde_json::json!({
            "type": "message_deleted",
            "conversation_id": conversation_id,
            "message_id": message_id,
            "deleted_at": deleted_at,
        });
        let payload = match serde_json::to_string(&event) {
            Ok(p) => p,
            Err(e) => {
                log::error!("broadcast_message_deleted: failed to serialize event for message {}: {}", message_id, e);
                return;
            }
        };

        let mut recipients: Vec<Uuid> = sqlx::query_scalar(
            r#"
            SELECT participant_id FROM conversation_participants
            WHERE conversation_id = $1 AND participant_id != $2
              AND status = 'accepted' AND left_at IS NULL
            "#,
        )
        .bind(conversation_id)
        .bind(actor_id)
        .fetch_all(pools.reader())
        .await
        .unwrap_or_else(|e| {
            log::error!("broadcast_message_deleted: failed to list participants for {}: {}", conversation_id, e);
            Vec::new()
        });
        recipients.push(actor_id);

        for recipient_id in recipients {
            if let Err(e) = self.cache.publish_user_event(&recipient_id.to_string(), &payload).await {
                log::error!("broadcast_message_deleted: failed to notify {} for message {}: {}", recipient_id, message_id, e);
            }
        }
    }

    pub async fn delete_message(
        &self,
        pools: &DbPools,
        message_id: Uuid,
        caller_id: Uuid,
    ) -> Result<Message, ChatError> {
        let row: Option<(Uuid, Uuid, DateTime<Utc>)> = sqlx::query_as(
            "SELECT conversation_id, sender_id, created_at FROM messages WHERE id = $1 AND deleted_at IS NULL",
        )
        .bind(message_id)
        .fetch_optional(pools.reader())
        .await?;

        let (conversation_id, sender_id, created_at) = row.ok_or(ChatError::NotFound)?;
        if sender_id != caller_id {
            return Err(ChatError::NotFound);
        }
        if Utc::now() - created_at > MESSAGE_DELETE_WINDOW {
            return Err(ChatError::DeleteWindowExpired);
        }

        let message: Message = sqlx::query_as(
            r#"
            UPDATE messages
            SET deleted_at = NOW(), text_content = NULL, media_url = NULL, media_metadata = NULL
            WHERE id = $1 AND sender_id = $2 AND deleted_at IS NULL
            RETURNING *
            "#,
        )
        .bind(message_id)
        .bind(caller_id)
        .fetch_optional(pools.writer())
        .await?
        .ok_or(ChatError::NotFound)?;

        if message.e2ee_envelope.is_some() {
            if let Err(e) = sqlx::query("DELETE FROM message_device_ciphertexts WHERE message_id = $1")
                .bind(message_id)
                .execute(pools.writer())
                .await
            {
                log::error!("delete_message: failed to purge ciphertexts for {}: {}", message_id, e);
            }
        }

        self.broadcast_message_deleted(
            pools,
            conversation_id,
            message_id,
            caller_id,
            message.deleted_at.unwrap_or_else(Utc::now),
        )
        .await;

        let recipient_ids: Vec<Uuid> = sqlx::query_scalar(
            r#"
            SELECT participant_id FROM conversation_participants
            WHERE conversation_id = $1 AND participant_id != $2
              AND status = 'accepted' AND left_at IS NULL
            "#,
        )
        .bind(conversation_id)
        .bind(caller_id)
        .fetch_all(pools.reader())
        .await
        .unwrap_or_else(|e| {
            log::error!("delete_message: failed to list participants for {}: {}", conversation_id, e);
            Vec::new()
        });

        for recipient_id in recipient_ids {
            let event = notif_shared::NotificationEvent::MessageDeleted {
                recipient_id,
                conversation_id,
                message_id,
            };
            let cache_clone = self.cache.clone();
            actix_web::rt::spawn(async move {
                if let Err(e) = notif_shared::publish_event(&cache_clone, &event).await {
                    log::error!("delete_message: failed to publish notification event: {}", e);
                }
            });
        }

        Ok(message)
    }

    async fn broadcast_message_edited(
        &self,
        pools: &DbPools,
        conversation_id: Uuid,
        message_id: Uuid,
        actor_id: Uuid,
        text_content: &str,
        edited_at: DateTime<Utc>,
    ) {
        let event = serde_json::json!({
            "type": "message_edited",
            "conversation_id": conversation_id,
            "message_id": message_id,
            "text_content": text_content,
            "edited_at": edited_at,
        });
        let payload = match serde_json::to_string(&event) {
            Ok(p) => p,
            Err(e) => {
                log::error!("broadcast_message_edited: failed to serialize event for message {}: {}", message_id, e);
                return;
            }
        };

        let mut recipients: Vec<Uuid> = sqlx::query_scalar(
            r#"
            SELECT participant_id FROM conversation_participants
            WHERE conversation_id = $1 AND participant_id != $2
              AND status = 'accepted' AND left_at IS NULL
            "#,
        )
        .bind(conversation_id)
        .bind(actor_id)
        .fetch_all(pools.reader())
        .await
        .unwrap_or_else(|e| {
            log::error!("broadcast_message_edited: failed to list participants for {}: {}", conversation_id, e);
            Vec::new()
        });
        recipients.push(actor_id);

        for recipient_id in recipients {
            if let Err(e) = self.cache.publish_user_event(&recipient_id.to_string(), &payload).await {
                log::error!("broadcast_message_edited: failed to notify {} for message {}: {}", recipient_id, message_id, e);
            }
        }
    }

    async fn broadcast_message_edited_e2ee(
        &self,
        message: &Message,
        per_user: &std::collections::HashMap<Uuid, Vec<CiphertextOut>>,
    ) {
        for (user_id, cts) in per_user {
            let event = serde_json::json!({
                "type": "message_edited",
                "conversation_id": message.conversation_id,
                "message_id": message.id,
                "text_content": serde_json::Value::Null,
                "edited_at": message.edited_at.unwrap_or_else(Utc::now),
                "e2ee_envelope": message.e2ee_envelope,
                "e2ee_ciphertexts": cts,
            });
            let Ok(payload) = serde_json::to_string(&event) else { continue };
            if let Err(e) = self.cache.publish_user_event(&user_id.to_string(), &payload).await {
                log::error!("broadcast_message_edited_e2ee: failed to notify {} for message {}: {}", user_id, message.id, e);
            }
        }
    }

    async fn broadcast_e2ee_enabled(&self, pools: &DbPools, conversation_id: Uuid, enabled_by: Uuid) {
        let Ok(members) = e2ee::member_user_ids(pools, conversation_id).await else { return };
        let payload = serde_json::json!({
            "type": "e2ee_enabled",
            "conversation_id": conversation_id,
            "enabled_at": Utc::now(),
            "enabled_by": enabled_by,
        })
        .to_string();
        for m in members {
            if let Err(e) = self.cache.publish_user_event(&m.to_string(), &payload).await {
                log::error!("broadcast_e2ee_enabled: failed to notify {}: {}", m, e);
            }
        }
    }

    pub async fn edit_message(
        &self,
        pools: &DbPools,
        message_id: Uuid,
        caller_id: Uuid,
        new_text: String,
        e2ee_payload: Option<E2eeSendPayload>,
    ) -> Result<Message, ChatError> {
        let new_text = new_text.trim().to_string();
        if e2ee_payload.is_none() && new_text.is_empty() {
            return Err(ChatError::EmptyMessage);
        }

        let row: Option<(Uuid, Uuid, DateTime<Utc>, bool, String)> = sqlx::query_as(
            "SELECT conversation_id, sender_id, created_at, is_disappearing, content_type::text \
             FROM messages WHERE id = $1 AND deleted_at IS NULL",
        )
        .bind(message_id)
        .fetch_optional(pools.reader())
        .await?;

        let (conversation_id, sender_id, created_at, is_disappearing, content_type) =
            row.ok_or(ChatError::NotFound)?;
        if sender_id != caller_id || is_disappearing || content_type != "text" {
            return Err(ChatError::NotFound);
        }
        if Utc::now() - created_at > MESSAGE_EDIT_WINDOW {
            return Err(ChatError::EditWindowExpired);
        }

        let (e2ee_fanout, _) = e2ee::gate_and_validate(pools, conversation_id, caller_id, e2ee_payload.as_ref(), false, false).await?;
        if let (Some(p), Some(fanout)) = (e2ee_payload.as_ref(), e2ee_fanout.as_ref()) {
            let mut tx = pools.writer().begin().await?;
            let message: Message = sqlx::query_as(
                r#"
                UPDATE messages
                SET e2ee_envelope = jsonb_set(jsonb_set(e2ee_envelope, '{rev}', to_jsonb($3::int)),
                                              '{sender_device_id}', to_jsonb($4::text)),
                    edited_at = NOW()
                WHERE id = $1 AND sender_id = $2
                  AND deleted_at IS NULL
                  AND is_disappearing = FALSE
                  AND e2ee_envelope IS NOT NULL
                  AND COALESCE((e2ee_envelope->>'rev')::int, 0) < $3
                  AND created_at > NOW() - make_interval(secs => $5)
                  AND EXISTS (
                      SELECT 1
                      FROM conversation_participants cp
                      JOIN conversations c ON c.id = messages.conversation_id
                      WHERE cp.conversation_id = messages.conversation_id
                        AND cp.participant_id = $2
                        AND cp.status = 'accepted'
                        AND cp.left_at IS NULL
                        AND c.group_deleted_at IS NULL
                  )
                RETURNING *
                "#,
            )
            .bind(message_id)
            .bind(caller_id)
            .bind(p.rev)
            .bind(p.sender_device_id.to_string())
            .bind(MESSAGE_EDIT_WINDOW.num_seconds() as f64)
            .fetch_optional(&mut *tx)
            .await?
            .ok_or(ChatError::NotFound)?;
            e2ee::store_ciphertexts(&mut tx, message_id, p, fanout, true).await?;
            tx.commit().await?;

            self.broadcast_message_edited_e2ee(
                &message,
                &e2ee::ciphertexts_by_user(p, fanout),
            )
            .await;
            return Ok(message);
        }

        let message: Message = sqlx::query_as(
            r#"
            UPDATE messages
            SET text_content = $3, edited_at = NOW()
            WHERE id = $1 AND sender_id = $2
              AND deleted_at IS NULL
              AND is_disappearing = FALSE
              AND content_type = 'text'
              AND created_at > NOW() - make_interval(secs => $4)
              AND EXISTS (
                  SELECT 1
                  FROM conversation_participants cp
                  JOIN conversations c ON c.id = messages.conversation_id
                  WHERE cp.conversation_id = messages.conversation_id
                    AND cp.participant_id = $2
                    AND cp.status = 'accepted'
                    AND cp.left_at IS NULL
                    AND c.group_deleted_at IS NULL
              )
            RETURNING *
            "#,
        )
        .bind(message_id)
        .bind(caller_id)
        .bind(&new_text)
        .bind(MESSAGE_EDIT_WINDOW.num_seconds() as f64)
        .fetch_optional(pools.writer())
        .await?
        .ok_or(ChatError::NotFound)?;

        self.broadcast_message_edited(
            pools,
            conversation_id,
            message_id,
            caller_id,
            &new_text,
            message.edited_at.unwrap_or_else(Utc::now),
        )
        .await;

        Ok(message)
    }

    pub async fn stop_location_share(
        &self,
        pools: &DbPools,
        conversation_id: Uuid,
        message_id: Uuid,
        sender_id: Uuid,
    ) -> Result<(), ChatError> {
        let updated: Option<Uuid> = sqlx::query_scalar(
            r#"
            UPDATE messages
            SET expires_at = NOW()
            WHERE id = $1
              AND conversation_id = $2
              AND sender_id = $3
              AND content_type = 'location'
              AND media_metadata->>'is_live_location' = 'true'
            RETURNING id
            "#,
        )
        .bind(message_id)
        .bind(conversation_id)
        .bind(sender_id)
        .fetch_optional(pools.writer())
        .await?;

        updated.map(|_| ()).ok_or(ChatError::NotFound)
    }

    pub async fn mark_read(
        &self,
        pools: &DbPools,
        conversation_id: Uuid,
        caller_id: Uuid,
        up_to_message_id: Uuid,
        opens_bit: bool,
    ) -> Result<(), ChatError> {
        let caller_row = self.get_participant_row(pools, conversation_id, caller_id).await?;

        if caller_row.status != ParticipantStatus::Accepted {
            return Ok(());
        }

        let mut tx = pools.writer().begin().await?;

        let target_row: Option<(DateTime<Utc>, Option<i64>)> = sqlx::query_as(
            "SELECT created_at, seq FROM messages WHERE id = $1 AND conversation_id = $2",
        )
        .bind(up_to_message_id)
        .bind(conversation_id)
        .fetch_optional(&mut *tx)
        .await?;

        let (_target_created_at, target_seq) = target_row.ok_or(ChatError::NotFound)?;
        let target_seq: i64 = target_seq.unwrap_or(0);

        let read_at = Utc::now();

        if opens_bit {
            sqlx::query(
                r#"
                UPDATE message_receipts
                SET opened_at = COALESCE(opened_at, NOW()),
                    delivered_at = COALESCE(delivered_at, NOW())
                WHERE message_id = $1 AND user_id = $2
                "#,
            )
            .bind(up_to_message_id)
            .bind(caller_id)
            .execute(&mut *tx)
            .await?;
        }

        if opens_bit {
            let new_bit_expiry = Utc::now() + BIT_OPENED_GRACE;
            sqlx::query(
                r#"
                UPDATE messages
                SET expires_at = $2,
                    media_url = NULL
                WHERE conversation_id = $1
                  AND is_disappearing = TRUE
                  AND content_type = 'bit'
                  AND id = $3
                "#,
            )
            .bind(conversation_id)
            .bind(new_bit_expiry)
            .bind(up_to_message_id)
            .execute(&mut *tx)
            .await?;
        }

        sqlx::query(
            r#"
            UPDATE conversation_participants
            SET last_read_message_id = $3,
                last_read_at         = $4,
                last_read_seq        = GREATEST(last_read_seq, $5),
                last_delivered_seq   = GREATEST(last_delivered_seq, $5),
                last_delivered_at    = CASE WHEN last_delivered_seq < $5 THEN $4 ELSE last_delivered_at END
            WHERE conversation_id = $1 AND participant_id = $2
            "#,
        )
        .bind(conversation_id)
        .bind(caller_id)
        .bind(up_to_message_id)
        .bind(read_at)
        .bind(target_seq)
        .execute(&mut *tx)
        .await?;

        tx.commit().await?;

        self.invalidate_conversation_list_caches(&[caller_id]).await;

        if let Ok(other_ids) = self.active_participant_ids(pools, conversation_id, caller_id).await {
            self.invalidate_conversation_list_caches(&other_ids).await;
            let is_group: bool = sqlx::query_scalar("SELECT is_group FROM conversations WHERE id = $1")
                .bind(conversation_id)
                .fetch_one(pools.reader())
                .await
                .unwrap_or(false);

            let receipts_visible = if is_group {
                true
            } else {
                let caller_enabled = self.get_chat_settings(pools, caller_id).await
                    .map(|s| s.read_receipts_enabled)
                    .unwrap_or(true);
                let mut all_enabled = caller_enabled;
                for other_id in &other_ids {
                    if !all_enabled {
                        break;
                    }
                    all_enabled = self.get_chat_settings(pools, *other_id).await
                        .map(|s| s.read_receipts_enabled)
                        .unwrap_or(true);
                }
                all_enabled
            };

            if receipts_visible {
                let event = serde_json::json!({
                    "type": "opened",
                    "conversation_id": conversation_id,
                    "up_to_message_id": up_to_message_id,
                    "user_id": caller_id,
                    "read_at": read_at,
                    "opens_bit": opens_bit,
                });
                if let Ok(payload) = serde_json::to_string(&event) {
                    for other_id in other_ids {
                        if let Err(e) = self.cache.publish_user_event(&other_id.to_string(), &payload).await {
                            log::error!("mark_read: failed to notify {} of read-up-to {}: {}", other_id, up_to_message_id, e);
                        }
                    }
                }
            }
        }

        Ok(())
    }

    pub async fn get_read_receipts(
        &self,
        pools: &DbPools,
        conversation_id: Uuid,
        caller_id: Uuid,
    ) -> Result<Vec<ParticipantReadReceipt>, ChatError> {
        self.get_participant_row(pools, conversation_id, caller_id).await?;

        let rows = sqlx::query_as::<_, ParticipantReadReceipt>(
            r#"
            SELECT participant_id AS user_id, last_read_message_id, last_read_at
            FROM conversation_participants
            WHERE conversation_id = $1 AND left_at IS NULL
            "#,
        )
        .bind(conversation_id)
        .fetch_all(pools.reader())
        .await?;

        Ok(rows)
    }

    pub async fn get_message_receipts(
        &self,
        pools: &DbPools,
        message_id: Uuid,
        caller_id: Uuid,
    ) -> Result<Vec<MessageReceiptDetail>, ChatError> {
        self.require_accepted_participant_for_message(pools, message_id, caller_id).await?;

        let rows: Vec<MessageReceiptDetail> = sqlx::query_as(
            r#"
            SELECT
                x.user_id,
                x.delivered_at,
                CASE WHEN (c.is_group
                    OR (COALESCE(reader.read_receipts_enabled, TRUE) AND COALESCE(sender.read_receipts_enabled, TRUE))
                ) THEN x.opened_at END AS opened_at
            FROM messages m
            JOIN conversations c ON c.id = m.conversation_id
            LEFT JOIN users sender ON sender.id = m.sender_id
            JOIN LATERAL (
                SELECT r.user_id, r.delivered_at, r.opened_at
                FROM message_receipts r
                WHERE m.content_type = 'bit' AND r.message_id = m.id
                UNION ALL
                SELECT rcp.participant_id,
                       CASE WHEN rcp.last_delivered_seq >= m.seq THEN rcp.last_delivered_at END,
                       CASE WHEN rcp.last_read_seq >= m.seq THEN rcp.last_read_at END
                FROM conversation_participants rcp
                WHERE m.content_type <> 'bit'
                  AND m.seq IS NOT NULL
                  AND rcp.conversation_id = m.conversation_id
                  AND rcp.participant_id != m.sender_id
                  AND COALESCE(rcp.joined_at, rcp.created_at) <= m.created_at
                  AND (rcp.left_at IS NULL OR rcp.left_at >= m.created_at)
            ) x ON TRUE
            LEFT JOIN users reader ON reader.id = x.user_id
            WHERE m.id = $1
            "#,
        )
        .bind(message_id)
        .fetch_all(pools.reader())
        .await?;

        Ok(rows)
    }

    pub async fn accept_request(&self, pools: &DbPools, conversation_id: Uuid, caller_id: Uuid) -> Result<(), ChatError> {
        let row = self.get_participant_row(pools, conversation_id, caller_id).await?;
        if row.status == ParticipantStatus::Accepted {
            return Ok(());
        }

        sqlx::query(
            "UPDATE conversation_participants SET status = 'accepted' WHERE id = $1",
        )
        .bind(row.id)
        .execute(pools.writer())
        .await?;

        self.invalidate_conversation_list_caches(&[caller_id]).await;
        self.invalidate_active_participants_cache(conversation_id).await;

        self.backfill_delivered_on_accept(pools, conversation_id, caller_id).await;

        let is_group: bool = sqlx::query_scalar("SELECT is_group FROM conversations WHERE id = $1")
            .bind(conversation_id)
            .fetch_one(pools.reader())
            .await
            .unwrap_or(false);

        if is_group {
            if let Some(added_by) = row.added_by {
                let group_name: Option<String> = sqlx::query_scalar(
                    "SELECT group_name FROM conversations WHERE id = $1",
                )
                .bind(conversation_id)
                .fetch_optional(pools.reader())
                .await
                .ok()
                .flatten();

                if let Some(group_name) = group_name {
                    let cache_clone = self.cache.clone();
                    let event = notif_shared::NotificationEvent::GroupInviteAccepted {
                        actor_id: caller_id,
                        recipient_id: added_by,
                        conversation_id,
                        group_name,
                    };
                    actix_web::rt::spawn(async move {
                        if let Err(e) = notif_shared::publish_event(&cache_clone, &event).await {
                            log::error!("accept_request: failed to publish notification event: {}", e);
                        }
                    });
                }
            }
        } else if let Ok(other_id) = self.other_participant_id(pools, conversation_id, caller_id).await {
            let cache_clone = self.cache.clone();
            let event = notif_shared::NotificationEvent::MessageRequestAccepted {
                actor_id: caller_id,
                recipient_id: other_id,
                conversation_id,
            };
            actix_web::rt::spawn(async move {
                if let Err(e) = notif_shared::publish_event(&cache_clone, &event).await {
                    log::error!("accept_request: failed to publish notification event: {}", e);
                }
            });
        }

        Ok(())
    }

    async fn backfill_delivered_on_accept(&self, pools: &DbPools, conversation_id: Uuid, user_id: Uuid) {
        let mut stamped: Vec<(Uuid, Uuid)> = match sqlx::query_as::<_, (Uuid, Uuid)>(
            r#"
            WITH prior AS (
                SELECT last_delivered_seq AS s
                FROM conversation_participants
                WHERE conversation_id = $1 AND participant_id = $2
            ),
            top AS (
                SELECT MAX(seq) AS s
                FROM messages
                WHERE conversation_id = $1
                  AND sender_id != $2
                  AND deleted_at IS NULL
                  AND content_type NOT IN ('system', 'bit')
                  AND seq IS NOT NULL
            ),
            bump AS (
                UPDATE conversation_participants cp
                SET last_delivered_seq = top.s,
                    last_delivered_at  = NOW()
                FROM top
                WHERE cp.conversation_id = $1
                  AND cp.participant_id = $2
                  AND top.s IS NOT NULL
                  AND top.s > cp.last_delivered_seq
                RETURNING 1
            )
            SELECT m.id, m.sender_id
            FROM messages m, prior
            WHERE m.conversation_id = $1
              AND m.sender_id != $2
              AND m.deleted_at IS NULL
              AND m.content_type NOT IN ('system', 'bit')
              AND m.seq > prior.s
            ORDER BY m.seq DESC
            LIMIT 200
            "#,
        )
        .bind(conversation_id)
        .bind(user_id)
        .fetch_all(pools.writer())
        .await
        {
            Ok(rows) => rows,
            Err(e) => {
                log::error!("backfill_delivered_on_accept: cursor catch-up failed for conversation {} user {}: {}", conversation_id, user_id, e);
                Vec::new()
            }
        };

        match sqlx::query_as::<_, (Uuid, Uuid)>(
            r#"
            UPDATE message_receipts r
            SET delivered_at = NOW()
            FROM messages m
            WHERE r.message_id = m.id
              AND m.conversation_id = $1
              AND m.content_type = 'bit'
              AND m.deleted_at IS NULL
              AND r.user_id = $2
              AND r.delivered_at IS NULL
            RETURNING r.message_id, m.sender_id
            "#,
        )
        .bind(conversation_id)
        .bind(user_id)
        .fetch_all(pools.writer())
        .await
        {
            Ok(mut rows) => stamped.append(&mut rows),
            Err(e) => {
                log::error!("backfill_delivered_on_accept: bit receipts failed for conversation {} user {}: {}", conversation_id, user_id, e);
            }
        }

        if stamped.is_empty() {
            return;
        }

        let mut sender_ids: Vec<Uuid> = stamped.iter().map(|(_, sender_id)| *sender_id).collect();
        sender_ids.sort();
        sender_ids.dedup();
        self.invalidate_conversation_list_caches(&sender_ids).await;

        for (message_id, sender_id) in stamped {
            let event = serde_json::json!({
                "type": "delivered",
                "message_id": message_id,
                "user_id": user_id,
            });
            if let Ok(payload) = serde_json::to_string(&event) {
                if let Err(e) = self.cache.publish_user_event(&sender_id.to_string(), &payload).await {
                    log::error!("backfill_delivered_on_accept: failed to notify sender {} for message {}: {}", sender_id, message_id, e);
                }
            }
        }
    }

    pub async fn auto_accept_pending_from(
        &self,
        pools: &DbPools,
        recipient_id: Uuid,
        sender_id: Uuid,
    ) -> Result<(), sqlx::Error> {
        self.auto_accept_pending_from_many(pools, recipient_id, &[sender_id]).await
    }

    pub async fn auto_accept_pending_from_many(
        &self,
        pools: &DbPools,
        recipient_id: Uuid,
        sender_ids: &[Uuid],
    ) -> Result<(), sqlx::Error> {
        if sender_ids.is_empty() {
            return Ok(());
        }

        let accepted: Vec<(Uuid, Uuid)> = sqlx::query_as(
            r#"
            UPDATE conversation_participants me
            SET status = 'accepted'
            FROM conversation_participants other
            JOIN conversations c ON c.id = other.conversation_id
            WHERE me.conversation_id = other.conversation_id
              AND me.participant_id = $1
              AND other.participant_id = ANY($2)
              AND me.status = 'pending'
              AND me.deleted_at IS NULL
              AND c.is_group = FALSE
            RETURNING me.conversation_id, other.participant_id
            "#,
        )
        .bind(recipient_id)
        .bind(sender_ids)
        .fetch_all(pools.writer())
        .await?;

        if !accepted.is_empty() {
            let mut affected: Vec<Uuid> = accepted.iter().map(|(_, sender)| *sender).collect();
            affected.push(recipient_id);
            self.invalidate_conversation_list_caches(&affected).await;
            for (conversation_id, _) in accepted {
                self.backfill_delivered_on_accept(pools, conversation_id, recipient_id).await;
            }
        }
        Ok(())
    }

    pub async fn decline_or_hide(&self, pools: &DbPools, conversation_id: Uuid, caller_id: Uuid) -> Result<(), ChatError> {
        let row = self.get_participant_row(pools, conversation_id, caller_id).await?;

        sqlx::query(
            "UPDATE conversation_participants SET deleted_at = NOW() WHERE id = $1",
        )
        .bind(row.id)
        .execute(pools.writer())
        .await?;

        self.invalidate_conversation_list_caches(&[caller_id]).await;
        Ok(())
    }

    pub async fn update_settings(
        &self,
        pools: &DbPools,
        conversation_id: Uuid,
        caller_id: Uuid,
        req: UpdateConversationSettingsRequest,
    ) -> Result<ConversationParticipant, ChatError> {
        let row = self.get_participant_row(pools, conversation_id, caller_id).await?;

        let (effective_muted_until, force_unmute) = match req.archived {
            Some(true) => (Some(Self::indefinite_mute_until()), false),
            Some(false) => (None, true),
            None => match req.muted_until {
                None => (None, false),
                Some(None) => (None, true),
                Some(Some(date)) => (Some(date), false),
            },
        };

        let updated = sqlx::query_as::<_, ConversationParticipant>(
            r#"
            UPDATE conversation_participants
            SET muted_until = CASE WHEN $5 THEN NULL ELSE COALESCE($2, muted_until) END,
                archived = COALESCE($3, archived),
                notifications_enabled = COALESCE($4, notifications_enabled)
            WHERE id = $1
            RETURNING *
            "#,
        )
        .bind(row.id)
        .bind(effective_muted_until)
        .bind(req.archived)
        .bind(req.notifications_enabled)
        .bind(force_unmute)
        .fetch_one(pools.writer())
        .await?;

        self.invalidate_conversation_list_caches(&[caller_id]).await;
        if req.archived.is_some() {
            let _ = self.cache.delete(&Self::typing_recipients_cache_key(conversation_id)).await;
        }
        Ok(updated)
    }

    fn indefinite_mute_until() -> DateTime<Utc> {
        Utc::now() + Duration::days(365 * 100)
    }

    pub async fn chat_block(&self, pools: &DbPools, blocker_id: Uuid, blocked_id: Uuid) -> Result<(), sqlx::Error> {
        sqlx::query(
            "INSERT INTO chat_blocks (blocker_id, blocked_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
        )
        .bind(blocker_id)
        .bind(blocked_id)
        .execute(pools.writer())
        .await?;
        self.write_through_chat_block(blocker_id, blocked_id, true).await;
        self.invalidate_conversation_list_caches(&[blocker_id, blocked_id]).await;
        Ok(())
    }

    pub async fn chat_unblock(&self, pools: &DbPools, blocker_id: Uuid, blocked_id: Uuid) -> Result<(), sqlx::Error> {
        sqlx::query("DELETE FROM chat_blocks WHERE blocker_id = $1 AND blocked_id = $2")
            .bind(blocker_id)
            .bind(blocked_id)
            .execute(pools.writer())
            .await?;
        self.write_through_chat_block(blocker_id, blocked_id, false).await;
        self.invalidate_conversation_list_caches(&[blocker_id, blocked_id]).await;
        Ok(())
    }

    async fn write_through_chat_block(&self, blocker_id: Uuid, blocked_id: Uuid, blocked: bool) {
        let (blocker, target) = (blocker_id.to_string(), blocked_id.to_string());
        let result = if blocked {
            self.cache.add_chat_block_edge(&blocker, &target).await
        } else {
            self.cache.remove_chat_block_edge(&blocker, &target).await
        };
        if let Err(e) = result {
            eprintln!("WARN: chat block cache write-through failed, dropping warm markers: {}", e);
            self.cache.drop_chat_blocked_warm(&blocker).await;
            self.cache.drop_chat_blocked_warm(&target).await;
        }
    }

    pub async fn get_conversation_details(
        &self,
        pools: &DbPools,
        conversation_id: Uuid,
        caller_id: Uuid,
    ) -> Result<ConversationSummary, ChatError> {
        #[derive(sqlx::FromRow)]
        struct Row {
            other_participant_id: Uuid,
            other_participant_type: ParticipantType,
            other_username: Option<String>,
            other_chat_name: Option<String>,
            other_profile_image_url: Option<String>,
            other_online_status_visibility: Option<VisibilityLevel>,
            other_last_seen_visibility: Option<VisibilityLevel>,
            other_last_seen_at: Option<DateTime<Utc>>,
            is_following: bool,
            status: ParticipantStatus,
            other_status: ParticipantStatus,
            archived: bool,
            muted_until: Option<DateTime<Utc>>,
            e2ee_enabled: bool,
        }

        let row = sqlx::query_as::<_, Row>(
            r#"
            SELECT
                other.participant_id      AS other_participant_id,
                other.participant_type    AS other_participant_type,
                u.username                 AS other_username,
                u.chat_name                AS other_chat_name,
                u.profile_image_url        AS other_profile_image_url,
                u.online_status_visibility AS other_online_status_visibility,
                u.last_seen_visibility     AS other_last_seen_visibility,
                u.last_seen_at             AS other_last_seen_at,
                EXISTS(
                    SELECT 1 FROM follows f
                    WHERE f.follower_id = $2 AND f.following_id = other.participant_id
                ) AS is_following,
                me.status,
                other.status               AS other_status,
                me.archived,
                CASE WHEN me.muted_until IS NOT NULL AND me.muted_until <= now() THEN NULL ELSE me.muted_until END AS muted_until,
                c.e2ee_enabled
            FROM conversation_participants me
            JOIN conversations c ON c.id = me.conversation_id
            JOIN conversation_participants other
                ON other.conversation_id = me.conversation_id AND other.participant_id != $2
            LEFT JOIN users u ON u.id = other.participant_id
            WHERE me.conversation_id = $1
              AND me.participant_id = $2
              AND me.deleted_at IS NULL
              AND c.is_group = false
            "#,
        )
        .bind(conversation_id)
        .bind(caller_id)
        .fetch_optional(pools.reader())
        .await?
        .ok_or(ChatError::NotFound)?;

        self.ensure_recipient_active(row.other_participant_id, row.other_participant_type).await?;

        let blocks = self.block_lookup(pools, caller_id, &[row.other_participant_id]).await?;
        let presence = if blocks.blocked_either.contains(&row.other_participant_id) {
            PresenceInfo::default()
        } else {
            let presence_map = self.bulk_presence(&[row.other_participant_id]).await;
            let entry = presence_map.get(&row.other_participant_id);
            Self::visible_presence(
                row.other_online_status_visibility.unwrap_or_default(),
                row.other_last_seen_visibility.unwrap_or_default(),
                row.is_following,
                entry.map(|e| e.online).unwrap_or(false),
                entry.map(|e| e.last_seen).or(row.other_last_seen_at),
            )
        };

        let display_name = row
            .other_chat_name
            .clone()
            .filter(|n| !n.trim().is_empty())
            .or_else(|| row.other_username.clone())
            .unwrap_or_else(|| row.other_participant_id.to_string());

        Ok(ConversationSummary {
            conversation_id,
            e2ee_enabled: row.e2ee_enabled,
            is_group: false,
            group_name: None,
            group_image_url: None,
            other_participant_id: row.other_participant_id,
            other_participant_type: row.other_participant_type,
            display_name,
            username: row.other_username,
            is_following: row.other_participant_type == ParticipantType::Service || row.is_following,
            last_message_preview: String::new(),
            last_message_content_type: None,
            last_message_at: None,
            last_message_sender_id: None,
            last_message_delivered: false,
            last_message_opened: false,
            unread_count: 0,
            status: row.status,
            profile_image_url: row.other_profile_image_url,
            other_status: row.other_status,
            archived: row.archived,
            muted_until: row.muted_until,
            presence,
            is_blocked: blocks.blocked_by_me.contains(&row.other_participant_id),
        })
    }

    const RING_TIMEOUT_SECS: u64 = 45;

    const PENDING_CALL_SIGNAL_TTL: usize = (Self::RING_TIMEOUT_SECS as usize) + 15;

    fn pending_call_signal_key(target_user_id: Uuid) -> String {
        format!("pending_call_signal:{}", target_user_id)
    }

    pub async fn stash_pending_call_signal(
        &self,
        call_id: Uuid,
        target_user_id: Uuid,
        frame_json: &str,
    ) {
        let key = Self::pending_call_signal_key(target_user_id);
        let value = format!("{}|{}", call_id, frame_json);
        if let Err(e) = self
            .cache
            .set(&key, value.as_str(), Self::PENDING_CALL_SIGNAL_TTL)
            .await
        {
            log::error!(
                "call {}: failed to stash pending call_signal for {}: {}",
                call_id, target_user_id, e
            );
        }
    }

    pub async fn take_pending_call_signal(&self, target_user_id: Uuid) -> Option<String> {
        let key = Self::pending_call_signal_key(target_user_id);
        let raw = self.cache.get::<String>(&key).await.ok().flatten();
        if raw.is_some() {
            let _ = self.cache.delete(&key).await;
        }
        raw.map(|r| Self::split_stashed_frame(&r).1)
    }

    fn split_stashed_frame(raw: &str) -> (Option<Uuid>, String) {
        if let Some((prefix, rest)) = raw.split_once('|') {
            if let Ok(id) = Uuid::parse_str(prefix) {
                return (Some(id), rest.to_string());
            }
        }
        (None, raw.to_string())
    }

    pub async fn pending_call_signal_for(
        &self,
        pools: &DbPools,
        call_id: Uuid,
        user_id: Uuid,
    ) -> Result<Option<String>, ChatError> {
        let call = sqlx::query_as::<_, Call>("SELECT * FROM calls WHERE id = $1")
            .bind(call_id)
            .fetch_optional(pools.writer())
            .await
            .map_err(ChatError::Db)?
            .ok_or(ChatError::NotFound)?;
        if call.caller_id != user_id && call.callee_id != user_id {
            return Err(ChatError::NotParticipant);
        }
        if !matches!(call.status, CallStatus::Ringing | CallStatus::Ongoing) {
            return Err(ChatError::CallEnded);
        }
        let key = Self::pending_call_signal_key(user_id);
        let raw = self.cache.get::<String>(&key).await.ok().flatten();
        Ok(raw.and_then(|r| {
            let (stashed_call, frame) = Self::split_stashed_frame(&r);
            (stashed_call == Some(call_id)).then_some(frame)
        }))
    }

    async fn clear_stash_if_call(cache: &CacheService, call_id: Uuid, user_id: Uuid) {
        let key = Self::pending_call_signal_key(user_id);
        if let Some(raw) = cache.get::<String>(&key).await.ok().flatten() {
            let (stashed_call, _) = Self::split_stashed_frame(&raw);
            if stashed_call.is_none() || stashed_call == Some(call_id) {
                let _ = cache.delete(&key).await;
            }
        }
    }

    pub async fn clear_pending_call_signal(&self, target_user_id: Uuid) {
        let key = Self::pending_call_signal_key(target_user_id);
        let _ = self.cache.delete(&key).await;
    }

    async fn resolve_display_name(&self, pools: &DbPools, user_id: Uuid) -> String {
        let row: Result<Option<(Option<String>, String)>, sqlx::Error> =
            sqlx::query_as("SELECT chat_name, username FROM users WHERE id = $1")
                .bind(user_id)
                .fetch_optional(pools.reader())
                .await;
        match row {
            Ok(Some((chat_name, username))) => chat_name.unwrap_or(username),
            Ok(None) => {
                log::warn!("resolve_display_name: user {} not found, falling back to raw id", user_id);
                user_id.to_string()
            }
            Err(e) => {
                log::error!("resolve_display_name: query failed for user {}: {}", user_id, e);
                user_id.to_string()
            }
        }
    }

    pub async fn create_call(
        &self,
        pools: &DbPools,
        conversation_id: Uuid,
        caller_id: Uuid,
        callee_id: Uuid,
        call_type: CallType,
    ) -> Result<CallCreated, ChatError> {
        let caller_row = self.get_participant_row(pools, conversation_id, caller_id).await?;
        if caller_row.status != ParticipantStatus::Accepted {
            return Err(ChatError::RequestNotAccepted);
        }
        let callee_row = self.get_participant_row(pools, conversation_id, callee_id).await?;
        if callee_row.status != ParticipantStatus::Accepted {
            return Err(ChatError::RequestNotAccepted);
        }
        if !self.can_message(pools, caller_id, callee_id).await? {
            return Err(ChatError::Blocked);
        }

        let caller_display_name = self.resolve_display_name(pools, caller_id).await;
        let callee_display_name = self.resolve_display_name(pools, callee_id).await;

        let turn_creds = turn::mint_credentials(&caller_id.to_string())
            .await
            .map_err(|e| {
                log::error!("create_call: failed to mint TURN credentials for caller {}: {}", caller_id, e);
                ChatError::Db(sqlx::Error::Protocol("turn credential mint failed".into()))
            })?;

        let mut tx = pools.writer().begin().await.map_err(ChatError::Db)?;

        let call = sqlx::query_as::<_, Call>(
            r#"
            INSERT INTO calls (conversation_id, caller_id, callee_id, call_type, status)
            VALUES ($1, $2, $3, $4, 'ringing')
            RETURNING *
            "#,
        )
        .bind(conversation_id)
        .bind(caller_id)
        .bind(callee_id)
        .bind(call_type)
        .fetch_one(&mut *tx)
        .await
        .map_err(ChatError::Db)?;

        let claim = sqlx::query("INSERT INTO active_calls (user_id, call_id) VALUES ($1, $3), ($2, $3)")
            .bind(caller_id)
            .bind(callee_id)
            .bind(call.id)
            .execute(&mut *tx)
            .await;

        match claim {
            Ok(_) => {
                tx.commit().await.map_err(ChatError::Db)?;
            }
            Err(sqlx::Error::Database(db_err)) if db_err.code().as_deref() == Some("23505") => {
                tx.rollback().await.map_err(ChatError::Db)?;

                let busy_call = sqlx::query_as::<_, Call>(
                    r#"
                    INSERT INTO calls (conversation_id, caller_id, callee_id, call_type, status, started_at, ended_at)
                    VALUES ($1, $2, $3, $4, 'busy', NOW(), NOW())
                    RETURNING *
                    "#,
                )
                .bind(conversation_id)
                .bind(caller_id)
                .bind(callee_id)
                .bind(call_type)
                .fetch_one(pools.writer())
                .await
                .map_err(ChatError::Db)?;

                return Ok(CallCreated {
                    turn: TurnCredentials {
                        urls: Vec::new(),
                        username: String::new(),
                        credential: String::new(),
                        expires_in_seconds: 0,
                    },
                    call: busy_call,
                    callee_reachable_now: false,
                    callee_name: callee_display_name,
                });
            }
            Err(e) => return Err(ChatError::Db(e)),
        }

        let callee_presence = self.bulk_presence(&[callee_id]).await;
        let mut callee_reachable_now = callee_presence.get(&callee_id).map(|e| e.online).unwrap_or(false);
    let event = serde_json::json!({
        "type": "incoming_call",
        "call_id": call.id,
        "conversation_id": conversation_id,
        "caller_id": caller_id,
        "caller_name": caller_display_name,
        "call_type": call_type,
    });
    match serde_json::to_string(&event) {
    Ok(payload) => match self.cache.publish_user_event(&callee_id.to_string(), &payload).await {
        Ok(0) => {
            log::warn!(
                "call {}: incoming_call published but no gateway subscriber for callee {} at publish time",
                call.id, callee_id
            );
            callee_reachable_now = false;
        }
        Ok(n) => {
            log::info!(
                "call {}: incoming_call published to callee {} ({} subscriber(s))",
                call.id, callee_id, n
            );
            callee_reachable_now = true;
        }
        Err(e) => log::error!("call {}: failed to publish incoming_call to callee {}: {}", call.id, callee_id, e),
    },
    Err(e) => log::error!("call {}: failed to serialize incoming_call event: {}", call.id, e),
}
    let ev = notif_shared::NotificationEvent::IncomingCall {
    call_id: call.id, conversation_id, caller_id, callee_id,
    call_type: call_type.to_string(),
    caller_name: caller_display_name.clone(),
    };
    let cache_clone = self.cache.clone();
    actix_web::rt::spawn(async move {
        for attempt in 1..=3u64 {
            match notif_shared::publish_event(&cache_clone, &ev).await {
                Ok(_) => break,
                Err(e) => {
                    log::error!("call: failed to publish IncomingCall voip event (attempt {}/3): {}", attempt, e);
                    if attempt < 3 {
                        tokio::time::sleep(std::time::Duration::from_millis(250 * attempt)).await;
                    }
                }
            }
        }
    });

    self.spawn_ring_timeout(pools.clone(), call.id, conversation_id, caller_id, callee_id);

        Ok(CallCreated {
            turn: TurnCredentials {
                urls: turn_creds.urls,
                username: turn_creds.username,
                credential: turn_creds.credential,
                expires_in_seconds: turn_creds.ttl,
            },
            call,
            callee_reachable_now,
            callee_name: callee_display_name,
        })
    }

    fn spawn_ring_timeout(
    &self,
    pools: DbPools,
    call_id: Uuid,
    conversation_id: Uuid,
    caller_id: Uuid,
    callee_id: Uuid,
) {
    let cache = self.cache.clone();
    actix_web::rt::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_secs(Self::RING_TIMEOUT_SECS)).await;

        let current = match sqlx::query_as::<_, Call>("SELECT * FROM calls WHERE id = $1")
            .bind(call_id)
            .fetch_optional(pools.reader())
            .await
        {
            Ok(Some(c)) => c,
            Ok(None) => return log::warn!("ring-timeout: call {} vanished before timeout fired", call_id),
            Err(e) => return log::error!("ring-timeout: failed to load call {}: {}", call_id, e),
        };

        if current.status != CallStatus::Ringing {
            return;
        }

        let mut tx = match pools.writer().begin().await {
            Ok(tx) => tx,
            Err(e) => return log::error!("ring-timeout: failed to open transaction for call {}: {}", call_id, e),
        };

        let updated = sqlx::query_as::<_, Call>(
            r#"
            UPDATE calls SET status = 'missed', ended_at = NOW()
            WHERE id = $1 AND status = 'ringing'
            RETURNING *
            "#,
        )
        .bind(call_id)
        .fetch_optional(&mut *tx)
        .await;

        match updated {
            Ok(Some(_)) => {}
            Ok(None) => return,
            Err(e) => return log::error!("ring-timeout: failed to mark call {} missed: {}", call_id, e),
        }

        if let Err(e) = sqlx::query("DELETE FROM active_calls WHERE call_id = $1")
            .bind(call_id)
            .execute(&mut *tx)
            .await
        {
            return log::error!("ring-timeout: failed to release active_calls for call {}: {}", call_id, e);
        }

        if let Err(e) = tx.commit().await {
            return log::error!("ring-timeout: failed to commit missed-call transaction for call {}: {}", call_id, e);
        }

        let event = serde_json::json!({
            "type": "call_status_changed",
            "call_id": call_id,
            "conversation_id": conversation_id,
            "status": "missed",
        });
        let Ok(payload) = serde_json::to_string(&event) else {
            return log::error!("ring-timeout: failed to serialize CallStatusChanged for call {}", call_id);
        };

        if let Err(e) = cache.publish_user_event(&caller_id.to_string(), &payload).await {
            log::error!("ring-timeout: failed to notify caller {} of missed call {}: {}", caller_id, call_id, e);
        }
        if let Err(e) = cache.publish_user_event(&callee_id.to_string(), &payload).await {
            log::error!("ring-timeout: failed to notify callee {} of missed call {}: {}", callee_id, call_id, e);
        }

        Self::clear_stash_if_call(&cache, call_id, caller_id).await;
        Self::clear_stash_if_call(&cache, call_id, callee_id).await;
    });
}

pub async fn update_call_status_and_notify(
    &self,
    pools: &DbPools,
    call_id: Uuid,
    status: CallStatus,
    acting_participant_id: Uuid,
) -> Result<Call, ChatError> {
    let existing = sqlx::query_as::<_, Call>("SELECT * FROM calls WHERE id = $1")
        .bind(call_id)
        .fetch_one(pools.reader())
        .await
        .map_err(ChatError::Db)?;

    if existing.caller_id != acting_participant_id && existing.callee_id != acting_participant_id {
        return Err(ChatError::NotParticipant);
    }

    let (call, applied) = self.transition_call_status(pools, call_id, status).await.map_err(ChatError::Db)?;

    if !applied && call.status != status {
        log::warn!(
            "call {}: ignoring illegal status transition requested by {} (call has already moved on)",
            call.id, acting_participant_id
        );
        return Ok(call);
    }

    if matches!(status, CallStatus::Declined | CallStatus::Ended | CallStatus::Ongoing) {
        let other_id = if call.caller_id == acting_participant_id { call.callee_id } else { call.caller_id };
        let status_str = match status {
            CallStatus::Declined => "declined",
            CallStatus::Ended => "ended",
            CallStatus::Ongoing => "ongoing",
            _ => unreachable!(),
        };
        let event = serde_json::json!({
            "type": "call_status_changed",
            "call_id": call.id,
            "conversation_id": call.conversation_id,
            "status": status_str,
        });
        if let Ok(payload) = serde_json::to_string(&event) {
            if let Err(e) = self.cache.publish_user_event(&other_id.to_string(), &payload).await {
                log::error!("call {}: failed to notify {} of status={}: {}", call.id, other_id, status_str, e);
            }
        }

        Self::clear_stash_if_call(&self.cache, call.id, call.callee_id).await;
        if !matches!(status, CallStatus::Ongoing) {
            Self::clear_stash_if_call(&self.cache, call.id, call.caller_id).await;
        }
    }

    Ok(call)
}
    pub async fn update_call_status(
        &self,
        pools: &DbPools,
        call_id: Uuid,
        status: CallStatus,
    ) -> Result<Call, sqlx::Error> {
        Ok(self.transition_call_status(pools, call_id, status).await?.0)
    }

    pub async fn transition_call_status(
        &self,
        pools: &DbPools,
        call_id: Uuid,
        status: CallStatus,
    ) -> Result<(Call, bool), sqlx::Error> {
        let (started_clause, ended_clause) = match status {
            CallStatus::Ongoing => ("NOW()", "ended_at"),
            CallStatus::Ended | CallStatus::Missed | CallStatus::Declined | CallStatus::Busy => ("started_at", "NOW()"),
            CallStatus::Ringing => ("started_at", "ended_at"),
        };
        let allowed_from = match status {
            CallStatus::Ongoing | CallStatus::Declined | CallStatus::Missed | CallStatus::Busy => "'ringing'",
            CallStatus::Ended => "'ringing', 'ongoing'",
            CallStatus::Ringing => "",
        };

        if !allowed_from.is_empty() {
            let query = format!(
                r#"UPDATE calls SET status = $2, started_at = {started_clause}, ended_at = {ended_clause} WHERE id = $1 AND status IN ({allowed_from}) RETURNING *"#
            );

            let mut tx = pools.writer().begin().await?;
            let updated = sqlx::query_as::<_, Call>(&query)
                .bind(call_id)
                .bind(status)
                .fetch_optional(&mut *tx)
                .await?;

            if let Some(call) = updated {
                if matches!(status, CallStatus::Ended | CallStatus::Missed | CallStatus::Declined | CallStatus::Busy) {
                    sqlx::query("DELETE FROM active_calls WHERE call_id = $1")
                        .bind(call_id)
                        .execute(&mut *tx)
                        .await?;
                }
                tx.commit().await?;
                return Ok((call, true));
            }
            tx.rollback().await?;
        }

        let current = sqlx::query_as::<_, Call>("SELECT * FROM calls WHERE id = $1")
            .bind(call_id)
            .fetch_one(pools.writer())
            .await?;
        Ok((current, false))
    }

    const HEARTBEAT_INTERVAL_SECS: u64 = 20;

    const STALE_CALL_MAX_SILENCE_SECS: u64 = Self::HEARTBEAT_INTERVAL_SECS * 3;

    const STALE_CALL_SWEEP_INTERVAL_SECS: u64 = 30;

    pub async fn record_call_heartbeat(
        &self,
        pools: &DbPools,
        call_id: Uuid,
        caller_id: Uuid,
    ) -> Result<(), ChatError> {
        let call = sqlx::query_as::<_, Call>("SELECT * FROM calls WHERE id = $1")
            .bind(call_id)
            .fetch_optional(pools.reader())
            .await
            .map_err(ChatError::Db)?
            .ok_or(ChatError::NotFound)?;

        if call.caller_id != caller_id && call.callee_id != caller_id {
            return Err(ChatError::NotParticipant);
        }

        if call.status != CallStatus::Ongoing {
            return Ok(());
        }

        sqlx::query("UPDATE calls SET last_heartbeat_at = NOW() WHERE id = $1 AND status = 'ongoing'")
            .bind(call_id)
            .execute(pools.writer())
            .await
            .map_err(ChatError::Db)?;

        Ok(())
    }

    pub fn spawn_stale_call_reaper(&self, pools: DbPools) {
        let chat = ChatService::new(self.cache.clone());
        actix_web::rt::spawn(async move {
            let mut interval = tokio::time::interval(std::time::Duration::from_secs(Self::STALE_CALL_SWEEP_INTERVAL_SECS));
            loop {
                interval.tick().await;
                if let Err(e) = chat.reap_stale_ongoing_calls(&pools).await {
                    log::error!("stale-call-reaper: sweep failed: {}", e);
                }
            }
        });
    }

    async fn reap_stale_ongoing_calls(&self, pools: &DbPools) -> Result<(), sqlx::Error> {
        let candidates = sqlx::query_as::<_, Call>(
            r#"
            SELECT * FROM calls
            WHERE status = 'ongoing'
              AND COALESCE(last_heartbeat_at, started_at) < NOW() - ($1 || ' seconds')::interval
            "#,
        )
        .bind(Self::STALE_CALL_MAX_SILENCE_SECS as i64)
        .fetch_all(pools.reader())
        .await?;

        for candidate in candidates {
            let mut tx = match pools.writer().begin().await {
                Ok(tx) => tx,
                Err(e) => {
                    log::error!("stale-call-reaper: failed to open transaction for call {}: {}", candidate.id, e);
                    continue;
                }
            };

            let claimed = sqlx::query_as::<_, Call>(
                r#"
                UPDATE calls SET status = 'ended', ended_at = NOW()
                WHERE id = $1 AND status = 'ongoing'
                RETURNING *
                "#,
            )
            .bind(candidate.id)
            .fetch_optional(&mut *tx)
            .await;

            let call = match claimed {
                Ok(Some(c)) => c,
                Ok(None) => continue,
                Err(e) => {
                    log::error!("stale-call-reaper: failed to claim call {}: {}", candidate.id, e);
                    continue;
                }
            };

            if let Err(e) = sqlx::query("DELETE FROM active_calls WHERE call_id = $1")
                .bind(call.id)
                .execute(&mut *tx)
                .await
            {
                log::error!("stale-call-reaper: failed to release active_calls for call {}: {}", call.id, e);
                continue;
            }

            if let Err(e) = tx.commit().await {
                log::error!("stale-call-reaper: failed to commit reap transaction for call {}: {}", call.id, e);
                continue;
            }

            log::warn!(
                "stale-call-reaper: ended call {} (caller {}, callee {}) -- no heartbeat in over {}s",
                call.id, call.caller_id, call.callee_id, Self::STALE_CALL_MAX_SILENCE_SECS
            );

            let event = serde_json::json!({
                "type": "call_status_changed",
                "call_id": call.id,
                "conversation_id": call.conversation_id,
                "status": "ended",
            });
            match serde_json::to_string(&event) {
                Ok(payload) => {
                    if let Err(e) = self.cache.publish_user_event(&call.caller_id.to_string(), &payload).await {
                        log::error!("stale-call-reaper: failed to notify caller {} for call {}: {}", call.caller_id, call.id, e);
                    }
                    if let Err(e) = self.cache.publish_user_event(&call.callee_id.to_string(), &payload).await {
                        log::error!("stale-call-reaper: failed to notify callee {} for call {}: {}", call.callee_id, call.id, e);
                    }
                }
                Err(e) => log::error!("stale-call-reaper: failed to serialize event for call {}: {}", call.id, e),
            }

            Self::clear_stash_if_call(&self.cache, call.id, call.caller_id).await;
            Self::clear_stash_if_call(&self.cache, call.id, call.callee_id).await;
        }

        Ok(())
    }

    pub async fn issue_turn_credentials(
        &self,
        pools: &DbPools,
        call_id: Uuid,
        participant_id: Uuid,
    ) -> Result<TurnCredentials, ChatError> {
        let call = sqlx::query_as::<_, Call>("SELECT * FROM calls WHERE id = $1")
            .bind(call_id)
            .fetch_optional(pools.writer())
            .await
            .map_err(ChatError::Db)?
            .ok_or(ChatError::NotFound)?;

        if call.caller_id != participant_id && call.callee_id != participant_id {
            return Err(ChatError::NotParticipant);
        }
        if !matches!(call.status, CallStatus::Ringing | CallStatus::Ongoing) {
            return Err(ChatError::CallEnded);
        }

        let creds = turn::mint_credentials(&participant_id.to_string())
            .await
            .map_err(|e| {
                log::error!("call {}: failed to mint TURN credentials for {}: {}", call.id, participant_id, e);
                ChatError::Db(sqlx::Error::Protocol("turn credential mint failed".into()))
            })?;

        Ok(TurnCredentials {
            urls: creds.urls,
            username: creds.username,
            credential: creds.credential,
            expires_in_seconds: creds.ttl,
        })
    }
}
const MAX_GROUP_SIZE: i64 = 250;

impl ChatService {
    pub async fn create_group(
        &self,
        pools: &DbPools,
        creator_id: Uuid,
        req: CreateGroupRequest,
    ) -> Result<Conversation, ChatError> {
        self.create_group_with_invite(pools, creator_id, req).await.map(|(conversation, _)| conversation)
    }

    pub async fn create_group_with_invite(
        &self,
        pools: &DbPools,
        creator_id: Uuid,
        req: CreateGroupRequest,
    ) -> Result<(Conversation, Option<GroupInviteLinkInfo>), ChatError> {
        let name = req.name.trim();
        if name.is_empty() {
            return Err(ChatError::InvalidGroupRequest);
        }

        let mut invitee_ids: Vec<Uuid> = req
            .participant_ids
            .into_iter()
            .filter(|id| *id != creator_id)
            .collect();
        invitee_ids.sort();
        invitee_ids.dedup();

        if invitee_ids.is_empty() {
            return Err(ChatError::InvalidGroupRequest);
        }
        if invitee_ids.len() > MAX_GROUP_CREATION_INVITEES {
            return Err(ChatError::TooManyParticipants);
        }

        self.ensure_no_block_for_group(pools, creator_id, &invitee_ids).await?;
        self.ensure_inviter_follows_for_group(pools, creator_id, &invitee_ids).await?;

        let conversation = sqlx::query_as::<_, Conversation>(
            r#"
            INSERT INTO conversations (is_group, group_name, group_image_url, created_by)
            VALUES (true, $1, $2, $3)
            RETURNING *
            "#,
        )
        .bind(name)
        .bind(req.image_url.as_deref())
        .bind(creator_id)
        .fetch_one(pools.writer())
        .await?;

        sqlx::query(
            r#"
            INSERT INTO conversation_participants
                (conversation_id, participant_id, participant_type, status, role, added_by, joined_at)
            VALUES ($1, $2, 'user', 'accepted', 'creator', NULL, NOW())
            "#,
        )
        .bind(conversation.id)
        .bind(creator_id)
        .execute(pools.writer())
        .await?;

        self.write_system_message(pools, conversation.id, creator_id, "group_created", None).await?;

        for invitee_id in &invitee_ids {
            self.add_group_member_row(pools, conversation.id, creator_id, *invitee_id).await?;
        }

        let invite_link = if req.invite_link_enabled {
            Some(self.upsert_invite_link(pools, conversation.id, creator_id, true, req.invite_token).await?)
        } else {
            None
        };

        Ok((conversation, invite_link))
    }

    async fn add_group_member_row(
        &self,
        pools: &DbPools,
        conversation_id: Uuid,
        actor_id: Uuid,
        invitee_id: Uuid,
    ) -> Result<(), ChatError> {
        let already_connected = self
            .recipient_already_connected(pools, invitee_id, ParticipantType::User, actor_id, ParticipantType::User)
            .await;
        let fresh_invite_status = if already_connected { ParticipantStatus::Accepted } else { ParticipantStatus::Pending };

        let final_status: Option<ParticipantStatus> = sqlx::query_scalar(
            r#"
            INSERT INTO conversation_participants
                (conversation_id, participant_id, participant_type, status, role, added_by, joined_at, left_at)
            VALUES ($1, $2, 'user', $3, 'member', $4, CASE WHEN $3 = 'accepted' THEN NOW() ELSE NULL END, NULL)
            ON CONFLICT (conversation_id, participant_id) DO UPDATE SET
                status = 'pending',
                role = 'member',
                added_by = excluded.added_by,
                joined_at = NULL,
                left_at = NULL,
                removed_by_creator = FALSE
            WHERE conversation_participants.left_at IS NOT NULL
            RETURNING status
            "#,
        )
        .bind(conversation_id)
        .bind(invitee_id)
        .bind(fresh_invite_status)
        .bind(actor_id)
        .fetch_optional(pools.writer())
        .await?;

        let Some(final_status) = final_status else {
            return Ok(());
        };

        self.write_system_message(pools, conversation_id, actor_id, "member_added", Some(invitee_id)).await?;
        if final_status == ParticipantStatus::Accepted {
            self.write_system_message(pools, conversation_id, invitee_id, "member_joined", None).await?;
        }

        let group_name: Option<String> = sqlx::query_scalar(
            "SELECT group_name FROM conversations WHERE id = $1",
        )
        .bind(conversation_id)
        .fetch_optional(pools.reader())
        .await
        .ok()
        .flatten();

        if let Some(group_name) = group_name {
            let cache_clone = self.cache.clone();
            let event = notif_shared::NotificationEvent::AddedToGroup {
                actor_id, recipient_id: invitee_id, conversation_id, group_name,
            };
            actix_web::rt::spawn(async move {
                if let Err(e) = notif_shared::publish_event(&cache_clone, &event).await {
                    log::error!("add_group_member_row: failed to publish notification event: {}", e);
                }
            });
        }

        Ok(())
    }

    pub async fn add_group_members(
        &self,
        pools: &DbPools,
        conversation_id: Uuid,
        caller_id: Uuid,
        req: AddGroupMembersRequest,
    ) -> Result<(), ChatError> {
        self.require_group_creator(pools, conversation_id, caller_id).await?;

        let mut ids: Vec<Uuid> = req.participant_ids.into_iter().collect();
        ids.sort();
        ids.dedup();
        if ids.is_empty() {
            return Err(ChatError::InvalidGroupRequest);
        }

        let current_count: i64 = sqlx::query_scalar(
            r#"SELECT COUNT(*) FROM conversation_participants WHERE conversation_id = $1 AND left_at IS NULL"#,
        )
        .bind(conversation_id)
        .fetch_one(pools.reader())
        .await?;

        if current_count + ids.len() as i64 > MAX_GROUP_SIZE {
            return Err(ChatError::TooManyParticipants);
        }

        let mut to_add: Vec<Uuid> = Vec::with_capacity(ids.len());
        for id in ids {
            let already_active_member: bool = sqlx::query_scalar(
                r#"SELECT EXISTS(SELECT 1 FROM conversation_participants WHERE conversation_id = $1 AND participant_id = $2 AND left_at IS NULL)"#,
            )
            .bind(conversation_id)
            .bind(id)
            .fetch_one(pools.reader())
            .await?;
            if already_active_member {
                continue;
            }
            to_add.push(id);
        }

        self.ensure_no_block_for_group(pools, caller_id, &to_add).await?;
        self.ensure_inviter_follows_for_group(pools, caller_id, &to_add).await?;

        for id in to_add {
            self.add_group_member_row(pools, conversation_id, caller_id, id).await?;
        }

        self.invalidate_active_participants_cache(conversation_id).await;
        Ok(())
    }

    pub async fn remove_group_member(
        &self,
        pools: &DbPools,
        conversation_id: Uuid,
        caller_id: Uuid,
        target_id: Uuid,
    ) -> Result<(), ChatError> {
        self.require_group_creator(pools, conversation_id, caller_id).await?;

        if target_id == caller_id {
            return Err(ChatError::InvalidGroupRequest);
        }

        let result = sqlx::query(
            r#"
            UPDATE conversation_participants
            SET left_at = NOW(), removed_by_creator = TRUE
            WHERE conversation_id = $1 AND participant_id = $2 AND left_at IS NULL
            "#,
        )
        .bind(conversation_id)
        .bind(target_id)
        .execute(pools.writer())
        .await?;

        if result.rows_affected() == 0 {
            return Err(ChatError::NotFound);
        }

        self.invalidate_active_participants_cache(conversation_id).await;
        self.write_system_message(pools, conversation_id, caller_id, "member_removed", Some(target_id)).await
    }

    pub async fn leave_group(
        &self,
        pools: &DbPools,
        conversation_id: Uuid,
        caller_id: Uuid,
    ) -> Result<(), ChatError> {
        let result = sqlx::query(
            r#"
            UPDATE conversation_participants
            SET left_at = NOW()
            WHERE conversation_id = $1 AND participant_id = $2 AND left_at IS NULL
            "#,
        )
        .bind(conversation_id)
        .bind(caller_id)
        .execute(pools.writer())
        .await?;

        if result.rows_affected() == 0 {
            return Err(ChatError::NotParticipant);
        }

        self.invalidate_active_participants_cache(conversation_id).await;
        self.write_system_message(pools, conversation_id, caller_id, "member_left", None).await
    }

    pub async fn promote_to_creator(
        &self,
        pools: &DbPools,
        conversation_id: Uuid,
        caller_id: Uuid,
        target_id: Uuid,
    ) -> Result<(), ChatError> {
        self.require_group_creator(pools, conversation_id, caller_id).await?;

        let result = sqlx::query(
            r#"
            UPDATE conversation_participants
            SET role = 'creator'
            WHERE conversation_id = $1 AND participant_id = $2
              AND status = 'accepted' AND left_at IS NULL
            "#,
        )
        .bind(conversation_id)
        .bind(target_id)
        .execute(pools.writer())
        .await?;

        if result.rows_affected() == 0 {
            return Err(ChatError::NotFound);
        }

        self.write_system_message(pools, conversation_id, caller_id, "creator_added", Some(target_id)).await
    }

    pub async fn update_group(
        &self,
        pools: &DbPools,
        conversation_id: Uuid,
        caller_id: Uuid,
        req: UpdateGroupRequest,
    ) -> Result<Conversation, ChatError> {
        self.require_group_creator(pools, conversation_id, caller_id).await?;

        if let Some(ref name) = req.name {
            if name.trim().is_empty() {
                return Err(ChatError::InvalidGroupRequest);
            }
            sqlx::query("UPDATE conversations SET group_name = $2 WHERE id = $1")
                .bind(conversation_id).bind(name.trim())
                .execute(pools.writer()).await?;
            self.write_system_message(pools, conversation_id, caller_id, "group_renamed", None).await?;
        }

        if let Some(ref image_url) = req.image_url {
            sqlx::query("UPDATE conversations SET group_image_url = $2 WHERE id = $1")
                .bind(conversation_id).bind(image_url)
                .execute(pools.writer()).await?;
            self.write_system_message(pools, conversation_id, caller_id, "group_image_changed", None).await?;
        }

        sqlx::query_as::<_, Conversation>("SELECT * FROM conversations WHERE id = $1")
            .bind(conversation_id)
            .fetch_one(pools.writer())
            .await
            .map_err(ChatError::Db)
    }

    pub async fn delete_group(
        &self,
        pools: &DbPools,
        conversation_id: Uuid,
        caller_id: Uuid,
    ) -> Result<(), ChatError> {
        self.require_group_creator(pools, conversation_id, caller_id).await?;

        let result = sqlx::query(
            r#"
            UPDATE conversations
            SET group_deleted_at = NOW(), group_deleted_by = $2
            WHERE id = $1 AND is_group = true AND group_deleted_at IS NULL
            "#,
        )
        .bind(conversation_id)
        .bind(caller_id)
        .execute(pools.writer())
        .await?;

        if result.rows_affected() == 0 {
            return Err(ChatError::NotFound);
        }

        self.invalidate_active_participants_cache(conversation_id).await;
        self.write_system_message(pools, conversation_id, caller_id, "group_deleted", None).await
    }

    pub async fn get_group_details(
        &self,
        pools: &DbPools,
        conversation_id: Uuid,
        caller_id: Uuid,
    ) -> Result<GroupDetailsResponse, ChatError> {
        let conversation = sqlx::query_as::<_, Conversation>(
            "SELECT * FROM conversations WHERE id = $1 AND is_group = true",
        )
        .bind(conversation_id)
        .fetch_optional(pools.reader())
        .await?
        .ok_or(ChatError::NotFound)?;

        #[derive(sqlx::FromRow)]
        struct Row {
            user_id: Uuid,
            display_name: String,
            username: String,
            profile_image_url: Option<String>,
            role: ParticipantRole,
            status: ParticipantStatus,
            added_by: Option<Uuid>,
            joined_at: Option<DateTime<Utc>>,
            left_at: Option<DateTime<Utc>>,
        }

        let rows = sqlx::query_as::<_, Row>(
            r#"
            SELECT
                cp.participant_id AS user_id,
                COALESCE(u.chat_name, u.username) AS display_name,
                u.username,
                u.profile_image_url,
                cp.role,
                cp.status,
                cp.added_by,
                cp.joined_at,
                cp.left_at
            FROM conversation_participants cp
            JOIN users u ON u.id = cp.participant_id
            WHERE cp.conversation_id = $1
            ORDER BY (cp.role = 'creator') DESC, cp.joined_at ASC NULLS LAST, cp.created_at ASC
            "#,
        )
        .bind(conversation_id)
        .fetch_all(pools.reader())
        .await?;

        let caller_row = rows.iter().find(|r| r.user_id == caller_id);
        if caller_row.is_none() {
            return Err(ChatError::NotParticipant);
        }
        let caller_is_creator = matches!(caller_row.map(|r| r.role), Some(ParticipantRole::Creator));

        let participants = rows
            .into_iter()
            .map(|r| GroupParticipantSummary {
                user_id: r.user_id,
                display_name: r.display_name,
                username: r.username,
                profile_image_url: r.profile_image_url,
                role: r.role,
                status: r.status,
                added_by: r.added_by,
                joined_at: r.joined_at,
                left_at: r.left_at,
            })
            .collect();

        let my_invite_link = if caller_is_creator {
            self.my_invite_link(pools, conversation_id, caller_id).await?
        } else {
            None
        };

        Ok(GroupDetailsResponse {
            conversation_id: conversation.id,
            name: conversation.group_name,
            image_url: conversation.group_image_url,
            created_by: conversation.created_by.unwrap_or(caller_id),
            caller_is_creator,
            group_deleted_at: conversation.group_deleted_at,
            group_deleted_by: conversation.group_deleted_by,
            participants,
            my_invite_link,
        })
    }

    async fn require_group_creator(
        &self,
        pools: &DbPools,
        conversation_id: Uuid,
        caller_id: Uuid,
    ) -> Result<(), ChatError> {
        let deleted: Option<bool> = sqlx::query_scalar(
            "SELECT group_deleted_at IS NOT NULL FROM conversations WHERE id = $1 AND is_group = true",
        )
        .bind(conversation_id)
        .fetch_optional(pools.reader())
        .await?;

        match deleted {
            None => return Err(ChatError::NotFound),
            Some(true) => return Err(ChatError::GroupDeleted),
            Some(false) => {}
        }

        let is_creator: bool = sqlx::query_scalar(
            r#"
            SELECT EXISTS(
                SELECT 1 FROM conversation_participants
                WHERE conversation_id = $1 AND participant_id = $2
                  AND role = 'creator' AND left_at IS NULL
            )
            "#,
        )
        .bind(conversation_id)
        .bind(caller_id)
        .fetch_one(pools.reader())
        .await?;

        if !is_creator {
            return Err(ChatError::NotGroupCreator);
        }
        Ok(())
    }

    async fn write_system_message(
        &self,
        pools: &DbPools,
        conversation_id: Uuid,
        actor_id: Uuid,
        event_type: &str,
        target_id: Option<Uuid>,
    ) -> Result<(), ChatError> {
        let metadata = serde_json::json!({
            "event_type": event_type,
            "target_id": target_id,
        });

        let message = sqlx::query_as::<_, Message>(
            r#"
            INSERT INTO messages (conversation_id, sender_id, sender_type, content_type, media_metadata, is_disappearing)
            VALUES ($1, $2, 'user', 'system', $3, false)
            RETURNING *
            "#,
        )
        .bind(conversation_id)
        .bind(actor_id)
        .bind(metadata)
        .fetch_one(pools.writer())
        .await?;

        sqlx::query(
            "UPDATE conversations SET last_message_id = $2, last_message_at = $3 WHERE id = $1",
        )
        .bind(conversation_id)
        .bind(message.id)
        .bind(message.created_at)
        .execute(pools.writer())
        .await?;

        let participant_ids: Vec<Uuid> = sqlx::query_scalar(
            "SELECT participant_id FROM conversation_participants WHERE conversation_id = $1 AND left_at IS NULL",
        )
        .bind(conversation_id)
        .fetch_all(pools.reader())
        .await
        .unwrap_or_default();

        let event = serde_json::json!({
            "type": "group_system_message",
            "conversation_id": conversation_id,
            "message": message,
        });
        if let Ok(payload) = serde_json::to_string(&event) {
            for participant_id in participant_ids {
                if let Err(e) = self.cache.publish_user_event(&participant_id.to_string(), &payload).await {
                    log::error!(
                        "write_system_message: failed to publish {} for conversation {} to {}: {}",
                        event_type, conversation_id, participant_id, e
                    );
                }
            }
        }

        Ok(())
    }
}

fn group_invite_base_url() -> &'static str {
    static BASE: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    BASE.get_or_init(|| {
        std::env::var("GROUP_INVITE_BASE_URL").expect("GROUP_INVITE_BASE_URL env var must be set")
    })
}

fn group_invite_url(token: &str) -> String {
    format!("{}/{}", group_invite_base_url(), token)
}

fn is_valid_client_invite_token(token: &str) -> bool {
    token.len() == 32 && token.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

struct ResolvedInvite {
    conversation_id: Uuid,
    creator_id: Uuid,
    group_name: Option<String>,
    group_image_url: Option<String>,
}

impl ChatService {
    pub async fn set_invite_link_enabled(
        &self,
        pools: &DbPools,
        conversation_id: Uuid,
        caller_id: Uuid,
        enabled: bool,
    ) -> Result<GroupInviteLinkInfo, ChatError> {
        self.require_group_creator(pools, conversation_id, caller_id).await?;
        self.upsert_invite_link(pools, conversation_id, caller_id, enabled, None).await
    }

    async fn upsert_invite_link(
        &self,
        pools: &DbPools,
        conversation_id: Uuid,
        creator_id: Uuid,
        enabled: bool,
        preferred_token: Option<String>,
    ) -> Result<GroupInviteLinkInfo, ChatError> {
        let mut candidates: Vec<String> = Vec::new();
        if let Some(t) = preferred_token.filter(|t| is_valid_client_invite_token(t)) {
            candidates.push(t);
        }
        candidates.push(Uuid::new_v4().simple().to_string());

        let mut last_err: Option<sqlx::Error> = None;
        for token in candidates {
            let res = sqlx::query_as::<_, (String, bool)>(
                r#"
                INSERT INTO group_invite_links (conversation_id, creator_id, token, enabled)
                VALUES ($1, $2, $3, $4)
                ON CONFLICT (conversation_id, creator_id)
                DO UPDATE SET enabled = EXCLUDED.enabled, updated_at = NOW()
                RETURNING token, enabled
                "#,
            )
            .bind(conversation_id)
            .bind(creator_id)
            .bind(&token)
            .bind(enabled)
            .fetch_one(pools.writer())
            .await;

            match res {
                Ok((token, enabled)) => {
                    return Ok(GroupInviteLinkInfo { url: group_invite_url(&token), token, enabled });
                }
                Err(sqlx::Error::Database(e)) if e.code().as_deref() == Some("23505") => {
                    last_err = Some(sqlx::Error::Database(e));
                    continue;
                }
                Err(e) => return Err(ChatError::Db(e)),
            }
        }
        Err(ChatError::Db(last_err.unwrap_or(sqlx::Error::RowNotFound)))
    }

    async fn my_invite_link(
        &self,
        pools: &DbPools,
        conversation_id: Uuid,
        user_id: Uuid,
    ) -> Result<Option<GroupInviteLinkInfo>, sqlx::Error> {
        let row: Option<(String, bool)> = sqlx::query_as(
            "SELECT token, enabled FROM group_invite_links WHERE conversation_id = $1 AND creator_id = $2",
        )
        .bind(conversation_id)
        .bind(user_id)
        .fetch_optional(pools.writer())
        .await?;
        Ok(row.map(|(token, enabled)| GroupInviteLinkInfo { url: group_invite_url(&token), token, enabled }))
    }

    async fn resolve_invite(&self, pools: &DbPools, token: &str) -> Result<ResolvedInvite, ChatError> {
        if token.len() < 8
            || token.len() > 64
            || !token.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
        {
            return Err(ChatError::NotFound);
        }

        let row: Option<(Uuid, Uuid, bool, Option<String>, Option<String>, bool)> = sqlx::query_as(
            r#"
            SELECT l.conversation_id, l.creator_id, l.enabled, c.group_name, c.group_image_url,
                   c.group_deleted_at IS NOT NULL
            FROM group_invite_links l
            JOIN conversations c ON c.id = l.conversation_id AND c.is_group = TRUE
            WHERE l.token = $1
            "#,
        )
        .bind(token)
        .fetch_optional(pools.writer())
        .await?;

        let (conversation_id, creator_id, enabled, group_name, group_image_url, deleted) =
            row.ok_or(ChatError::NotFound)?;
        if deleted {
            return Err(ChatError::GroupDeleted);
        }
        if !enabled {
            return Err(ChatError::NotFound);
        }

        let owner_is_active_creator: bool = sqlx::query_scalar(
            r#"
            SELECT EXISTS(
                SELECT 1 FROM conversation_participants
                WHERE conversation_id = $1 AND participant_id = $2
                  AND role = 'creator' AND status = 'accepted' AND left_at IS NULL
            )
            "#,
        )
        .bind(conversation_id)
        .bind(creator_id)
        .fetch_one(pools.writer())
        .await?;
        if !owner_is_active_creator {
            return Err(ChatError::NotFound);
        }

        Ok(ResolvedInvite { conversation_id, creator_id, group_name, group_image_url })
    }

    pub async fn get_invite_preview(
        &self,
        pools: &DbPools,
        token: &str,
        caller_id: Uuid,
    ) -> Result<GroupInvitePreview, ChatError> {
        let invite = self.resolve_invite(pools, token).await?;

        let member_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM conversation_participants WHERE conversation_id = $1 AND status = 'accepted' AND left_at IS NULL",
        )
        .bind(invite.conversation_id)
        .fetch_one(pools.writer())
        .await?;

        let already_member: bool = sqlx::query_scalar(
            r#"
            SELECT EXISTS(
                SELECT 1 FROM conversation_participants
                WHERE conversation_id = $1 AND participant_id = $2
                  AND status = 'accepted' AND left_at IS NULL
            )
            "#,
        )
        .bind(invite.conversation_id)
        .bind(caller_id)
        .fetch_one(pools.writer())
        .await?;

        Ok(GroupInvitePreview {
            conversation_id: invite.conversation_id,
            name: invite.group_name,
            image_url: invite.group_image_url,
            member_count,
            already_member,
            invited_by_name: self.resolve_display_name(pools, invite.creator_id).await,
        })
    }

    pub async fn join_via_invite_link(
        &self,
        pools: &DbPools,
        token: &str,
        caller_id: Uuid,
    ) -> Result<Conversation, ChatError> {
        let invite = self.resolve_invite(pools, token).await?;

        let blocks = self.block_lookup(pools, caller_id, &[invite.creator_id]).await?;
        if blocks.blocked_either.contains(&invite.creator_id) {
            return Err(ChatError::NotFound);
        }

        let conversation = sqlx::query_as::<_, Conversation>("SELECT * FROM conversations WHERE id = $1")
            .bind(invite.conversation_id)
            .fetch_one(pools.writer())
            .await?;

        let existing: Option<(ParticipantStatus, Option<DateTime<Utc>>, bool)> = sqlx::query_as(
            r#"
            SELECT status, left_at, removed_by_creator
            FROM conversation_participants
            WHERE conversation_id = $1 AND participant_id = $2
            "#,
        )
        .bind(invite.conversation_id)
        .bind(caller_id)
        .fetch_optional(pools.writer())
        .await?;

        match existing {
            Some((ParticipantStatus::Accepted, None, _)) => return Ok(conversation),
            Some((_, Some(_), true)) => return Err(ChatError::NotFound),
            _ => {}
        }

        let is_pending_invitee = matches!(existing, Some((_, None, _)));
        if !is_pending_invitee {
            let current_count: i64 = sqlx::query_scalar(
                "SELECT COUNT(*) FROM conversation_participants WHERE conversation_id = $1 AND left_at IS NULL",
            )
            .bind(invite.conversation_id)
            .fetch_one(pools.writer())
            .await?;
            if current_count + 1 > MAX_GROUP_SIZE {
                return Err(ChatError::TooManyParticipants);
            }
        }

        if existing.is_none() {
            sqlx::query(
                r#"
                INSERT INTO conversation_participants
                    (conversation_id, participant_id, participant_type, status, role, added_by, joined_at)
                VALUES ($1, $2, 'user', 'accepted', 'member', $3, NOW())
                "#,
            )
            .bind(invite.conversation_id)
            .bind(caller_id)
            .bind(invite.creator_id)
            .execute(pools.writer())
            .await?;
        } else {
            sqlx::query(
                r#"
                UPDATE conversation_participants
                SET status = 'accepted',
                    role = CASE WHEN left_at IS NOT NULL THEN 'member' ELSE role END,
                    added_by = CASE WHEN left_at IS NOT NULL THEN $3 ELSE added_by END,
                    joined_at = NOW(), left_at = NULL, deleted_at = NULL, removed_by_creator = FALSE
                WHERE conversation_id = $1 AND participant_id = $2
                "#,
            )
            .bind(invite.conversation_id)
            .bind(caller_id)
            .bind(invite.creator_id)
            .execute(pools.writer())
            .await?;
        }

        self.invalidate_active_participants_cache(invite.conversation_id).await;
        self.invalidate_conversation_list_caches(&[caller_id]).await;
        self.write_system_message(
            pools,
            invite.conversation_id,
            caller_id,
            "member_joined_via_link",
            Some(invite.creator_id),
        )
        .await?;

        Ok(conversation)
    }

    pub async fn get_group_suggestions(
        &self,
        pools: &DbPools,
        caller_id: Uuid,
    ) -> Result<GroupSuggestionsResponse, ChatError> {
        let mut recent: Vec<GroupSuggestion> = sqlx::query_as(
            r#"
            SELECT u.id AS user_id,
                   COALESCE(u.chat_name, u.username) AS display_name,
                   u.username,
                   u.profile_image_url,
                   NOT (u.group_invites_from_followers_only AND NOT EXISTS (
                       SELECT 1 FROM follows f WHERE f.follower_id = $1 AND f.following_id = u.id
                   )) AS can_add_to_group
            FROM conversation_participants me
            JOIN conversations c ON c.id = me.conversation_id
                 AND c.is_group = FALSE AND c.last_message_at IS NOT NULL
            JOIN conversation_participants other ON other.conversation_id = c.id
                 AND other.participant_id <> me.participant_id AND other.participant_type = 'user'
            JOIN users u ON u.id = other.participant_id
            WHERE me.participant_id = $1 AND me.participant_type = 'user' AND me.deleted_at IS NULL
            ORDER BY c.last_message_at DESC
            LIMIT 60
            "#,
        )
        .bind(caller_id)
        .fetch_all(pools.reader())
        .await?;

        let mut followers: Vec<GroupSuggestion> = sqlx::query_as(
            r#"
            SELECT u.id AS user_id,
                   COALESCE(u.chat_name, u.username) AS display_name,
                   u.username,
                   u.profile_image_url,
                   NOT (u.group_invites_from_followers_only AND NOT EXISTS (
                       SELECT 1 FROM follows f2 WHERE f2.follower_id = $1 AND f2.following_id = u.id
                   )) AS can_add_to_group
            FROM follows fo
            JOIN users u ON u.id = fo.follower_id
            WHERE fo.following_id = $1
            ORDER BY u.username
            LIMIT 100
            "#,
        )
        .bind(caller_id)
        .fetch_all(pools.reader())
        .await?;

        let mut candidate_ids: Vec<Uuid> = recent.iter().chain(followers.iter()).map(|s| s.user_id).collect();
        candidate_ids.sort();
        candidate_ids.dedup();
        candidate_ids.retain(|id| *id != caller_id);

        let blocks = self.block_lookup(pools, caller_id, &candidate_ids).await?;
        let id_strs: Vec<String> = candidate_ids.iter().map(|id| id.to_string()).collect();
        let hidden = self.cache.content_hidden_subset(&id_strs).await;

        let keep = |s: &GroupSuggestion| {
            s.user_id != caller_id
                && !blocks.blocked_either.contains(&s.user_id)
                && !hidden.contains(&s.user_id.to_string())
        };
        recent.retain(|s| keep(s));
        recent.truncate(20);
        let recent_ids: std::collections::HashSet<Uuid> = recent.iter().map(|s| s.user_id).collect();
        followers.retain(|s| keep(s) && !recent_ids.contains(&s.user_id));

        Ok(GroupSuggestionsResponse { recent, followers })
    }
}
