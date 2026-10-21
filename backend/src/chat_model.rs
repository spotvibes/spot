// SPDX-License-Identifier: AGPL-3.0

use chrono::{DateTime, Utc};
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::Value as JsonValue;
use sqlx::FromRow;
use uuid::Uuid;
use crate::models::e2ee::{CiphertextOut, E2eeSendPayload};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "text", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum ParticipantType {
    User,
    Service,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "text", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum ParticipantStatus {
    Accepted,
    Pending,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "text", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum MessageContentType {
    Text,
    Image,
    Video,
    Voice,
    Location,
    File,
    Bit,
    System,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "text", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum VisibilityLevel {
    Off,
    Public,
    Followers,
}

impl Default for VisibilityLevel {
    fn default() -> Self {
        VisibilityLevel::Public
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "text", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum ParticipantRole {
    Creator,
    Member,
}

impl Default for ParticipantRole {
    fn default() -> Self {
        ParticipantRole::Member
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "text", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum CallType {
    Voice,
    Video,
}

impl std::fmt::Display for CallType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let s = match self {
            CallType::Voice => "voice",
            CallType::Video => "video",
        };
        write!(f, "{}", s)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "text", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum CallStatus {
    Ringing,
    Ongoing,
    Ended,
    Missed,
    Declined,
    Busy,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct Conversation {
    pub id: Uuid,
    pub is_group: bool,
    pub last_message_id: Option<Uuid>,
    pub last_message_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub group_name: Option<String>,
    pub group_image_url: Option<String>,
    pub created_by: Option<Uuid>,
    pub group_deleted_at: Option<DateTime<Utc>>,
    pub group_deleted_by: Option<Uuid>,
    #[serde(default)]
    pub e2ee_enabled: bool,
    #[serde(default)]
    pub e2ee_enabled_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub e2ee_enabled_by: Option<Uuid>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct ConversationParticipant {
    pub id: Uuid,
    pub conversation_id: Uuid,
    pub participant_id: Uuid,
    pub participant_type: ParticipantType,
    pub status: ParticipantStatus,
    pub muted_until: Option<DateTime<Utc>>,
    pub archived: bool,
    pub notifications_enabled: bool,
    pub last_read_message_id: Option<Uuid>,
    pub deleted_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub role: ParticipantRole,
    pub added_by: Option<Uuid>,
    pub joined_at: Option<DateTime<Utc>>,
    pub left_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct MessageMediaMetadata {
    pub duration_ms: Option<i64>,
    pub file_size_bytes: Option<i64>,
    pub mime_type: Option<String>,
    pub thumbnail_url: Option<String>,
    pub width: Option<i32>,
    pub height: Option<i32>,
    pub lat: Option<f64>,
    pub lng: Option<f64>,
    pub is_live_location: Option<bool>,
    pub view_duration_seconds: Option<i32>,
    pub event_type: Option<String>,
    pub target_id: Option<Uuid>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct Message {
    pub id: Uuid,
    pub conversation_id: Uuid,
    pub sender_id: Uuid,
    pub sender_type: ParticipantType,
    pub content_type: MessageContentType,
    pub text_content: Option<String>,
    pub media_url: Option<String>,
    pub media_metadata: Option<JsonValue>,
    pub reply_to_message_id: Option<Uuid>,
    pub is_disappearing: bool,
    pub expires_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub deleted_at: Option<DateTime<Utc>>,
    pub edited_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub e2ee_envelope: Option<JsonValue>,
    #[sqlx(skip)]
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub e2ee_ciphertexts: Option<Vec<CiphertextOut>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct MessageReceipt {
    pub message_id: Uuid,
    pub user_id: Uuid,
    pub delivered_at: Option<DateTime<Utc>>,
    pub opened_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct MessageReaction {
    pub id: Uuid,
    pub message_id: Uuid,
    pub user_id: Uuid,
    pub emoji: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct ChatBlock {
    pub blocker_id: Uuid,
    pub blocked_id: Uuid,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct Call {
    pub id: Uuid,
    pub conversation_id: Uuid,
    pub caller_id: Uuid,
    pub callee_id: Uuid,
    pub call_type: CallType,
    pub status: CallStatus,
    pub started_at: Option<DateTime<Utc>>,
    pub ended_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub last_heartbeat_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Deserialize)]
pub struct SendMessageRequest {
    pub content_type: MessageContentType,
    pub text_content: Option<String>,
    pub media_url: Option<String>,
    pub media_metadata: Option<MessageMediaMetadata>,
    pub reply_to_message_id: Option<Uuid>,
    pub is_disappearing: Option<bool>,
    #[serde(default)]
    pub e2ee: Option<E2eeSendPayload>,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
pub struct UpdateConversationSettingsRequest {
    #[serde(default, deserialize_with = "deserialize_some")]
    pub muted_until: Option<Option<DateTime<Utc>>>,
    #[serde(default)]
    pub archived: Option<bool>,
    #[serde(default)]
    pub notifications_enabled: Option<bool>,
}
fn deserialize_some<'de, D, T>(deserializer: D) -> Result<Option<T>, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de>,
{
    Deserialize::deserialize(deserializer).map(Some)
}
 
#[derive(Debug, Deserialize)]
pub struct StartDirectConversationRequest {
    pub other_id: Uuid,
    pub other_type: ParticipantType,
}

#[derive(Debug, Deserialize)]
pub struct MarkReadRequest {
    pub up_to_message_id: Uuid,
    #[serde(default)]
    pub opens_bit: bool,
}

#[derive(Debug, Deserialize)]
pub struct EditMessageRequest {
    #[serde(default)]
    pub text: String,
    #[serde(default)]
    pub e2ee: Option<E2eeSendPayload>,
}

#[derive(Debug, Deserialize)]
pub struct AddReactionRequest {
    pub emoji: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct MessageWithReceipt {
    #[serde(flatten)]
    pub message: Message,
    pub delivered: bool,
    pub opened: bool,
    pub opened_at: Option<DateTime<Utc>>,
    pub reactions: Vec<MessageReaction>,
}

#[derive(Debug, Deserialize)]
pub struct CreateCallRequest {
    pub call_type: CallType,
}

   #[derive(Debug, Clone, serde::Serialize)]
   pub struct TurnCredentials {
       pub urls: Vec<String>,
       pub username: String,
       pub credential: String,
       #[serde(rename = "expires_in_seconds")]
       pub expires_in_seconds: i64,
   }

#[derive(Debug, Serialize)]
pub struct CallCreated {
    #[serde(flatten)]
    pub call: Call,
    pub turn: TurnCredentials,
    pub callee_reachable_now: bool,
    pub callee_name: String,    
}
#[derive(Debug, Deserialize)]
pub struct UpdateChatSettingsRequest {
    pub chat_name: Option<String>,
    pub online_status_visibility: Option<VisibilityLevel>,
    pub last_seen_visibility: Option<VisibilityLevel>,
    pub read_receipts_enabled: Option<bool>,
    pub chats_from_followers_only: Option<bool>,
    pub group_invites_from_followers_only: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct ChatSettings {
    pub chat_name: Option<String>,
    pub online_status_visibility: VisibilityLevel,
    pub last_seen_visibility: VisibilityLevel,
    pub read_receipts_enabled: bool,
    pub chats_from_followers_only: bool,
    pub group_invites_from_followers_only: bool,
}

#[derive(Debug, Deserialize)]
pub struct UpdateCallStatusRequest {
    pub status: CallStatus,
}

pub const MAX_GROUP_CREATION_INVITEES: usize = 249;

#[derive(Debug, Deserialize)]
pub struct CreateGroupRequest {
    pub name: String,
    pub participant_ids: Vec<Uuid>,
    pub image_url: Option<String>,
    #[serde(default)]
    pub invite_link_enabled: bool,
    #[serde(default)]
    pub invite_token: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct AddGroupMembersRequest {
    pub participant_ids: Vec<Uuid>,
}

#[derive(Debug, Deserialize)]
pub struct UpdateGroupRequest {
    pub name: Option<String>,
    pub image_url: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct PromoteGroupCreatorRequest {
    pub user_id: Uuid,
}

#[derive(Debug, Clone, Serialize)]
pub struct GroupParticipantSummary {
    pub user_id: Uuid,
    pub display_name: String,
    pub username: String,
    pub profile_image_url: Option<String>,
    pub role: ParticipantRole,
    pub status: ParticipantStatus,
    pub added_by: Option<Uuid>,
    pub joined_at: Option<DateTime<Utc>>,
    pub left_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize)]
pub struct GroupDetailsResponse {
    pub conversation_id: Uuid,
    pub name: Option<String>,
    pub image_url: Option<String>,
    pub created_by: Uuid,
    pub caller_is_creator: bool,
    pub group_deleted_at: Option<DateTime<Utc>>,
    pub group_deleted_by: Option<Uuid>,
    pub participants: Vec<GroupParticipantSummary>,
    pub my_invite_link: Option<GroupInviteLinkInfo>,
}

#[derive(Debug, Clone, Serialize)]
pub struct GroupConversationResponse {
    #[serde(flatten)]
    pub conversation: Conversation,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub invite_link: Option<GroupInviteLinkInfo>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConversationSummary {
    pub conversation_id: Uuid,
    pub is_group: bool,
    #[serde(default)]
    pub e2ee_enabled: bool,
    pub group_name: Option<String>,
    pub group_image_url: Option<String>,
    pub other_participant_id: Uuid,
    pub other_participant_type: ParticipantType,
    pub display_name: String,
    pub username: Option<String>,
    pub is_following: bool,
    #[serde(default)]
    pub is_blocked: bool,
    pub last_message_preview: String,
    pub last_message_content_type: Option<MessageContentType>,
    pub last_message_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub last_message_sender_id: Option<Uuid>,
    pub last_message_delivered: bool,
    pub last_message_opened: bool,
    pub unread_count: i64,
    pub status: ParticipantStatus,
    pub profile_image_url: Option<String>,
    pub other_status: ParticipantStatus,
    pub archived: bool,
    pub muted_until: Option<DateTime<Utc>>,
    pub presence: PresenceInfo,
}

#[derive(Debug, Clone, Serialize)]
pub struct DirectConversationResponse {
    #[serde(flatten)]
    pub conversation: Conversation,
    pub other_status: ParticipantStatus,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, Default)]
pub struct PresenceInfo {
    pub online: Option<bool>,
    pub last_seen: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GroupInviteLinkInfo {
    pub token: String,
    pub url: String,
    pub enabled: bool,
}

#[derive(Debug, Deserialize)]
pub struct SetInviteLinkRequest {
    pub enabled: bool,
}

#[derive(Debug, Deserialize)]
pub struct JoinGroupViaLinkRequest {
    pub token: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct GroupInvitePreview {
    pub conversation_id: Uuid,
    pub name: Option<String>,
    pub image_url: Option<String>,
    pub member_count: i64,
    pub already_member: bool,
    pub invited_by_name: String,
}

#[derive(Debug, Clone, Serialize, FromRow)]
pub struct GroupSuggestion {
    pub user_id: Uuid,
    pub display_name: String,
    pub username: String,
    pub profile_image_url: Option<String>,
    pub can_add_to_group: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct GroupSuggestionsResponse {
    pub recent: Vec<GroupSuggestion>,
    pub followers: Vec<GroupSuggestion>,
}
